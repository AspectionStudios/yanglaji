# yanglaji 洋垃圾

> 洋垃圾 — "foreign trash" — is the Chinese second-hand market's own name for
> cheap ex-datacenter hardware. This tool goes and prices it.

A gray-market price scout for the
[cluster-comparison chart](https://github.com/AspectionStudios) project: it
mines asking/sold prices for accelerators and memory across the channels that
are readable **without a login**, in the languages those markets actually use,
and reports everything normalized to **USD per GB** against the chart's
current floors.

## Why

The same card routinely trades at two prices an ocean apart — e.g. an
Instinct MI210 around ¥4,000–4,500 (≈ $600) on Chinese second-hand channels
while US eBay asks $4,369. English-only searching from a US egress mostly
finds the expensive ocean. The slang is the search key:

| Term | Meaning |
|---|---|
| 洋垃圾 | "foreign trash" — cheap ex-datacenter gear |
| 魔改 | modded (e.g. clamshell 48GB RTX 4090s) |
| 矿卡 | ex-mining cards |
| 闲鱼 | Xianyu, Alibaba's second-hand marketplace |
| 二手 | second-hand |

## What it does

For each probe in `probes.json` (a model, its memory size, its class):

1. Fetches direct price-tracker pages (`urls` — gpusold, dimmsum, ...).
2. Runs the in-language query pack (`queries`) through Brave Search HTML
   (primary; its snippets carry prices) with Bing HTML as fallback, then
   follows the top result links and mines those pages too.
3. Mines prices ($ / € / ¥ / ￥ / 元）, converts at the FX rates in
   `config.json`, and keeps a price only if one of the probe's `match`
   tokens appears within 350 characters of it — the relevance gate that
   keeps marketplace hub pages from flooding the sample with other
   products' prices.
4. Writes `report.md`: min / median / median-$/GB per probe, plus flags for
   any probe whose median beats its class floor on the chart (floors live
   in `config.json`, labeled with the chart row they came from).

Output is a **scout-grade signal**: snippet-mined asking prices across two
oceans land in one distribution, so read min + median together — and verify
against the live listing before any ruling.

## Build & run

```sh
zig build            # Zig 0.15+
./zig-out/bin/yanglaji [--probes probes.json] [--config config.json] [--out report.md]
```

Transport is `curl` from a child process — the seam that already speaks
most machines' egress (proxies, system CA). Parsing, FX, $/GB math and the
report are pure Zig. No accounts, no API keys, no login anywhere: every
source is a public page. That is a design constraint, not an oversight —
the tool is agent-bootstrappable end to end.

## Adding a probe

```json
{ "name": "Instinct MI250", "class": "hbm", "gb": 64,
  "match": ["MI250"],
  "queries": ["MI250 闲鱼 价格", "MI250 洋垃圾", "MI250 used price ebay"],
  "urls": [] }
```

`class` is one of `hbm` / `compute` / `memory` (selects the floor to flag
against). `match` tokens gate which mined prices belong to this probe.

## Known limits (v1)

- Xianyu/Taobao proper sit behind login walls; the tool reads them through
  search snippets, trackers and mirrors instead. It sees fewer listings
  than a logged-in session would — the prices it does see are real.
- Minimums are noisy (per-GB prices, shipping, accessories). Medians are
  the signal.
- Search engines throttle bursty querying; the tool sleeps briefly between
  page fetches. A full 12-probe run takes a few minutes.
