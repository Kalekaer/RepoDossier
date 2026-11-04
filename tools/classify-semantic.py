#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""classify-semantic.py — P2-5 分类升级：fastembed(BAAI/bge-small-zh-v1.5) 语义向量**独立复核** v2

纪律与 `dupes-probe.ps1` 一致：**只产证据，绝不改任何现有数据** ✓
  · 不写 `data/projects.jsonl`、不改 taxonomy、不自动重分类
  · 只写 `data/classify-semantic.jsonl`（派生物，整份重写）+ 打印报告

v2 相对 v1 的**校准**（v1 首跑 suggest 136 条，其中 23 条是兜底类目造成的假信号 ✗）：
  ① **无锚点类目不参与判定**：`其他/其他工具` 这类既无说明也无关键词的类目 ⇒ sim 恒 0.000，
     它下面的条目一律判 `no-anchor`（语义判不了，交人工/规则），**不再冒充 suggest** ✓
  ② **类目文档只用前 N 个关键词**（`--kw`，默认 6）：v1 把整张关键词表拼进文档（「AI绘画」20 个词）
     ⇒ 关键词多的类目形成"语义吸引子"、把别的条目吸过来 ✗
  ③ **绝对相似度下限**（`--min-sim`，默认 0.62）：只看相对差会放大噪声（v1 实测
     `pester/Pester → DSH 生态/DSH 配置` 这种明显错的建议就是这么冒出来的 ✗）⇒ 必须同时满足
     `margin ≥ suggest` **且** `best_sim ≥ min-sim` 才算 `suggest`，否则降级为 `weak`（证据不足）
  ④ **手工小样本质量门**（`--fixture`）：8 条人工核过的中文条目（文本→正确类目），
     断言 top-1 命中率 ≥ `--min-acc`（默认 0.75）⇒ 不达标就**不产出**结论 ✗

用法（一般不用手敲：由 `classify-semantic.ps1` 包装 ✓）：
  python classify-semantic.py                       # 完整复核 + 报告
  python classify-semantic.py --selftest            # 纯逻辑自检（不加载模型）
  python classify-semantic.py --fixture             # 质量门：手工小样本 top-1 命中率
  python classify-semantic.py --list-models         # 打印 fastembed 支持的模型名
  python classify-semantic.py --model X --suggest .06 --min-sim .65 --kw 8 --top 30
退出码：0 正常；1 输入/质量门不达标；2 环境未就绪（fastembed 没装 / 模型下不来）
"""
import argparse
import json
import math
import os
import sys

# stdout/stderr -> UTF-8: when redirected (no tty) Python falls back to the system locale
# (GBK on this box) and crashes on CJK / check marks. Belt and braces next to the wrapper env var.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8')
    except Exception:
        pass

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault('FASTEMBED_CACHE_PATH', os.path.join(WS, 'data', '_models'))
os.environ.setdefault('HF_HOME', os.path.join(WS, 'data', '_models', 'hf'))
os.environ.setdefault('HF_ENDPOINT', 'https://hf-mirror.com')   # CN mirror; explicit env var still wins

DEFAULT_MODEL = 'BAAI/bge-small-zh-v1.5'


def P(*parts):
    return os.path.join(WS, *parts)


def read_jsonl(path):
    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def cosine(a, b):
    num = 0.0
    na = 0.0
    nb = 0.0
    for x, y in zip(a, b):
        num += x * y
        na += x * x
        nb += y * y
    if na <= 0 or nb <= 0:
        return 0.0
    return float(num / (math.sqrt(na) * math.sqrt(nb)))   # numpy float32 is not JSON serializable


def load_categories(kw_limit=6):
    """→ [(l1, l2, doc, anchored)]；文档 = 一级说明 + 二级名 + **前 kw_limit 个关键词**"""
    tax = json.load(open(P('data', 'taxonomy.json'), encoding='utf-8'))
    cats = tax.get('一级分类') or {}
    out = []
    for l1, node in cats.items():
        desc = (node or {}).get('说明', '') or ''
        children = (node or {}).get('children') or {}
        for l2, kws in children.items():
            kws = list(kws or [])
            sel = kws if kw_limit <= 0 else kws[:kw_limit]
            doc = ' '.join(x for x in [l1, l2, desc, ' '.join(sel)] if x)
            # 有说明或有关键词 = 有锚点；只有类目名 = 语义判不了（如「其他/其他工具」）
            anchored = bool(desc.strip()) or bool(kws)
            out.append((l1, l2, doc, anchored))
    extra = tax.get('_other') or tax.get('_其他分类') or {}
    if isinstance(extra, dict):
        for l2, kws in (extra.get('children') or {}).items():
            kws = list(kws or [])
            sel = kws if kw_limit <= 0 else kws[:kw_limit]
            doc = ' '.join(x for x in ['other', l2, ' '.join(sel)] if x)
            out.append(('other', l2, doc, bool(kws)))
    return out


def project_text(p):
    h = p.get('human') or {}
    parts = [h.get('one_liner') or '', p.get('description') or '', ' '.join(p.get('function_tags') or [])]
    return ' '.join(x for x in parts if x).strip()[:1200]


def current_cat(p):
    c = p.get('category') or {}
    return (c.get('l1') or '', c.get('l2') or '')


def verdict_of(cur_sim, best_sim, is_top1, cur_anchored, suggest, watch, min_sim):
    """判定顺序：无锚点 → 命中 → 绝对下限 → 相对差"""
    if not is_top1 and not cur_anchored:
        return 'no-anchor'      # 当前类目没有语义锚点 ⇒ 这套方法判不了它 ✓
    if is_top1:
        return 'match'
    if best_sim < min_sim:
        return 'weak'           # 绝对相似度太低 ⇒ 证据不足，别动 ✓
    margin = best_sim - cur_sim
    if margin >= suggest:
        return 'suggest'
    if margin >= watch:
        return 'watch'
    return 'close'


FIXTURE = [
    ('一个把 PDF 转成 Markdown 的本地工具，不联网，纯命令行。', '办公/PDF 与阅读'),
    ('给程序员用的命令行 AI 编程助手，能读写你本机的代码仓库、跑测试。', '开发/编程助手'),
    ('在浏览器里跑的修图工具：抠图、去背景、批量压缩，全部本地完成。', '设计/图片处理'),
    ('给 macOS 用的文件搜索器：按文件内容找东西，不用记得文件名。', '效率/文件管理'),
    ('把一个团队的 AI 技能、规则和 MCP 配置放进 git 仓库并自动同步。', 'AI/AI Agent'),
    ('给自家服务器装的容器编排部署面板，一条命令起服务并看日志。', '运维/部署托管'),
    ('把一堆 Markdown 笔记和文档整理成静态网站的工具。', '办公/文档处理'),
    ('中国象棋引擎，带开局库和 AI 对战。', '其他/其他工具'),
]


def selftest():
    ok = 0
    bad = 0

    def chk(name, cond):
        nonlocal ok, bad
        if cond:
            ok += 1
            print('  ✓ ' + name)
        else:
            bad += 1
            print('  ✗ ' + name)

    chk('余弦：同向量 = 1.0', abs(cosine([1, 0, 0], [1, 0, 0]) - 1.0) < 1e-9)
    chk('余弦：正交 = 0', abs(cosine([1, 0], [0, 1])) < 1e-9)
    chk('余弦：零向量不炸 = 0', cosine([0, 0], [1, 1]) == 0.0)
    cat = load_categories(kw_limit=6)
    chk('类目数 >= 20 且文档非空', len(cat) >= 20 and all(d.strip() for _, _, d, _ in cat))
    chk('类目文档都非空壳（>=3 字符）', all(len(d.strip()) > 2 for _, _, d, _ in cat))
    chk('有锚点类目占多数（>= 20）', sum(1 for _, _, _, a in cat if a) >= 20)
    chk('判定：当前 top1 ⇒ match', verdict_of(0.9, 0.9, True, True, 0.05, 0.02, 0.62) == 'match')
    chk('判定：差 0.06 且 sim 0.86 ≥ 下限 ⇒ suggest',
        verdict_of(0.80, 0.86, False, True, 0.05, 0.02, 0.62) == 'suggest')   # 用 0.86：0.85-0.80 在 IEEE 双精度里是 0.0499.. < 0.05 ✗)
    chk('判定：差 0.05 但 sim 0.50 < 下限 ⇒ weak（v1 会误判成 suggest ✗）',
        verdict_of(0.45, 0.50, False, True, 0.05, 0.02, 0.62) == 'weak')
    chk('判定：差 0.03 ⇒ watch', verdict_of(0.80, 0.83, False, True, 0.05, 0.02, 0.62) == 'watch')
    chk('判定：差 0.005 ⇒ close', verdict_of(0.80, 0.805, False, True, 0.05, 0.02, 0.62) == 'close')
    chk('判定：当前类目无锚点 ⇒ no-anchor（不冒充 suggest）',
        verdict_of(0.0, 0.67, False, False, 0.05, 0.02, 0.62) == 'no-anchor')
    chk('项目文本拼接不炸', project_text({'human': {'one_liner': 'x'}, 'description': 'y', 'function_tags': ['z']}) == 'x y z')
    chk('手工小样本至少 8 条', len(FIXTURE) >= 8)
    print('')
    if bad:
        print('自检：%d 通过 / %d 失败' % (ok, bad))
        return 1
    print('自检：%d 通过 / 0 失败 ✓' % ok)
    return 0


def build_model(name):
    from fastembed import TextEmbedding
    return TextEmbedding(model_name=name)


def run_fixture(model, labels, min_acc):
    """质量门：8 条人工核过的条目，看 top-1 命中率"""
    cat_vecs = [list(v) for v in model.query_embed([d for _, _, d, _ in labels])]
    vecs = [list(v) for v in model.embed([t for t, _ in FIXTURE])]
    hit = 0
    print('')
    print('=== 质量门：手工小样本 top-1 ===')
    for (text, want), vec in zip(FIXTURE, vecs):
        sims = sorted(((cosine(vec, cv), L1, L2) for cv, (L1, L2, _, _) in zip(cat_vecs, labels)), key=lambda x: -x[0])
        got = '%s/%s' % (sims[0][1], sims[0][2])
        is_ok = (got == want)
        hit += 1 if is_ok else 0
        print('  %s want=%-16s got=%-16s sim=%.3f  %s' % ('✓' if is_ok else '✗', want, got, sims[0][0], text[:22]))
    acc = hit / float(len(FIXTURE))
    print('  命中 %d/%d = %.0f%%（门槛 %.0f%%）' % (hit, len(FIXTURE), acc * 100, min_acc * 100))
    if acc < min_acc:
        print('  ❌ 未过质量门 ⇒ 本工具暂不产出改类建议（先把类目文档/阈值调对 ✓）')
        return 1
    print('  ✓ 过质量门')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--list-models', action='store_true')
    ap.add_argument('--fixture', action='store_true', help='跑手工小样本质量门')
    ap.add_argument('--model', default=DEFAULT_MODEL)
    ap.add_argument('--suggest', type=float, default=0.05, help='余弦差下限（默认 0.05；v1 的 0.02 太松 ✗）')
    ap.add_argument('--watch', type=float, default=0.02, help='余弦差观察线（默认 0.02）')
    ap.add_argument('--min-sim', type=float, default=0.62, help='绝对相似度下限（默认 0.62）')
    ap.add_argument('--kw', type=int, default=0, help='类目文档里放几个关键词，0 = 全部（默认 0）')
    ap.add_argument('--min-acc', type=float, default=0.75, help='质量门最低 top-1 命中率')
    ap.add_argument('--top', type=int, default=25)
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    if args.list_models:
        from fastembed import TextEmbedding as _TE
        for _m in _TE.list_supported_models():
            print(_m.get('model') if isinstance(_m, dict) else getattr(_m, 'model', str(_m)))
        return 0

    if args.selftest:
        return selftest()

    labels = load_categories(kw_limit=args.kw)
    if not labels:
        print('❌ taxonomy 里读不到类目（data/taxonomy.json 结构变了？）')
        return 1
    prj_path = P('data', 'projects.jsonl')
    if not os.path.exists(prj_path):
        print('❌ 找不到 data/projects.jsonl')
        return 1
    projects = read_jsonl(prj_path)
    if not projects:
        print('❌ data/projects.jsonl 是空的')
        return 1

    try:
        model = build_model(args.model)
    except Exception as e:
        print('❌ 模型不可用（名字不对/下载失败/离线？）：%s' % e)
        print('   提示：用 --list-models 看可用模型，再 --model 换一个')
        return 2

    if args.fixture:
        return run_fixture(model, labels, args.min_acc)

    try:
        cat_vecs = [list(v) for v in model.query_embed([d for _, _, d, _ in labels])]
        prj_vecs = [list(v) for v in model.embed([project_text(p) for p in projects])]
    except Exception as e:
        print('❌ 嵌入失败：%s' % e)
        return 2

    anchored = {(L1, L2): a for L1, L2, _, a in labels}
    rows = []
    counts = {'match': 0, 'close': 0, 'watch': 0, 'suggest': 0, 'weak': 0, 'no-anchor': 0, 'no-cat': 0}
    for p, vec in zip(projects, prj_vecs):
        l1, l2 = current_cat(p)
        sims = [(cosine(vec, cv), L1, L2) for cv, (L1, L2, _, _) in zip(cat_vecs, labels)]
        sims.sort(key=lambda x: -x[0])
        top1 = sims[0]
        top2 = sims[1] if len(sims) > 1 else (0.0, '', '')
        cur_sim = 0.0
        for s, L1, L2 in sims:
            if (L1, L2) == (l1, l2):
                cur_sim = s
                break
        if not l1 and not l2:
            v = 'no-cat'
        else:
            v = verdict_of(cur_sim, top1[0], (top1[1], top1[2]) == (l1, l2),
                           bool(anchored.get((l1, l2), False)), args.suggest, args.watch, args.min_sim)
        counts[v] += 1
        rows.append({
            'id': p.get('id'), 'cur': '%s/%s' % (l1, l2), 'top1': '%s/%s' % (top1[1], top1[2]),
            'top2': '%s/%s' % (top2[1], top2[2]),
            'sim_cur': round(cur_sim, 4), 'sim_top1': round(top1[0], 4),
            'margin': round(top1[0] - cur_sim, 4), 'verdict': v,
            'cur_anchored': bool(anchored.get((l1, l2), False)), 'text_len': len(project_text(p)),
        })

    out_path = P('data', 'classify-semantic.jsonl')
    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')

    if args.json:
        print(json.dumps({'projects': len(rows), 'categories': len(labels), 'counts': counts,
                          'model': args.model, 'suggest_threshold': args.suggest,
                          'min_sim': args.min_sim, 'kw_limit': args.kw,
                          'suggest': sorted([r for r in rows if r['verdict'] == 'suggest'],
                                            key=lambda x: -x['margin'])[:args.top]},
                         ensure_ascii=False, indent=2))
        return 0

    print('')
    print('=== 语义分类复核（P2-5，只产证据）===')
    print('  模型 %s ｜ 项目 %d 条 ｜ 类目 %d 个（文档 = 一级说明 + 二级名 + 关键词上限 %d，0=全部）' % (
        args.model, len(rows), len(labels), args.kw))
    print('  判定：绝对下限 sim ≥ %.2f 且余弦差 ≥ %.2f ⇒ suggest ｜ 差 ≥ %.2f ⇒ watch' % (
        args.min_sim, args.suggest, args.watch))
    print('  结果：match %d ｜ close %d ｜ watch %d ｜ suggest %d ｜ weak %d ｜ 无锚点 %d ｜ 无分类 %d' % (
        counts['match'], counts['close'], counts['watch'], counts['suggest'],
        counts['weak'], counts['no-anchor'], counts['no-cat']))
    sug = sorted([r for r in rows if r['verdict'] == 'suggest'], key=lambda x: -x['margin'])
    if sug:
        print('')
        print('  ── 建议改类（top %d，按余弦差降序；已过绝对下限 %.2f ✓）──' % (min(args.top, len(sug)), args.min_sim))
        for r in sug[:args.top]:
            print('    [%+.3f sim %.2f] %-18s %s → %s   （top2 %s）' % (
                r['margin'], r['sim_top1'], r['cur'], r['id'], r['top1'], r['top2']))
    watch = sorted([r for r in rows if r['verdict'] == 'watch'], key=lambda x: -x['margin'])
    if watch:
        print('')
        print('  ── 观察（%d 条，差 %.2f–%.2f ⇒ 证据不够硬，不动 ✓）──' % (len(watch), args.watch, args.suggest))
        for r in watch[:8]:
            print('    [%+.3f] %-18s %s → %s' % (r['margin'], r['cur'], r['id'], r['top1']))
    na = [r for r in rows if r['verdict'] == 'no-anchor']
    if na:
        print('')
        print('  ── 无锚点类目（%d 条，语义判不了 ⇒ 交人工/规则，**不冒充 suggest** ✓）──' % len(na))
        print('    %s' % ', '.join(r['id'] for r in na[:8]))
    print('')
    print('  产物：data/classify-semantic.jsonl（%d 行）' % len(rows))
    print('  ⚠️ 本工具**不改任何现有数据**；语义相似 ≠ 分类正确（还受「DSH 生态门槛」「只加不改」约束）⇒ 改动必须人工逐条确认 ✗')
    return 0


if __name__ == '__main__':
    sys.exit(main())
