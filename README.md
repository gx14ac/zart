## zart
bitmap based art table.

## Benchmark

### Basic bench
![Basic Benchmark Results](assets/basic_benchmark.png)

基本性能評価では、以下の3つの観点から性能を測定しています。
- プレフィックス数に応じた挿入・検索性能
- メモリ使用量の推移
- マッチ率の確認

### Realistic bench
![Realistic Benchmark Results](assets/realistic_benchmark.png)

実運用環境を想定した評価では、以下の点に注目しています。
- パフォーマンスとメモリ使用量の関係
- キャッシュヒット率とマッチ率の推移

### Multithreading bench
![Advanced Benchmark Results](assets/advanced_benchmark.png)

マルチスレッド環境での性能評価では、以下を測定しています。
- スレッド数に応じたスケーラビリティ
- メモリ断片化の影響

## ベンチマークの実行方法

全体のベンチマークテストを確認したい場合。
```bash
make all-bench
```
`/assets`ディレクトリにcsvと画像が作成されます。

単体のベンチマークテストを実行する場合。
```bash
# 基本性能評価
zig build bench -Doptimize=ReleaseFast

# 実運用環境に近い性能評価
zig build rt_bench -Doptimize=ReleaseFast

# マルチスレッド性能評価
zig build advanced_bench -Doptimize=ReleaseFast
```

## Setup
`nix develop`

## CGO

## Ref
[art](https://github.com/hariguchi/art)
