#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
from pathlib import Path

# グラフのスタイル設定
plt.style.use('default')  # seabornの代わりにdefaultスタイルを使用
sns.set_theme()  # seabornのテーマを設定
plt.rcParams['font.family'] = 'Hiragino Sans'  # macOS用
plt.rcParams['axes.unicode_minus'] = False

def plot_basic_benchmark():
    """基本的なベンチマーク結果の可視化"""
    df = pd.read_csv('assets/basic_bench_results.csv')
    
    # 図の作成
    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 15))
    fig.suptitle('BART Basic Benchmark Results\n基本性能評価', fontsize=16, y=0.98)
    
    # 1. パフォーマンスグラフ
    ax1.plot(df['prefix_count'], df['insert_rate'] / 1e6, 'o-', label='Insert Rate (M ops/sec)')
    ax1.plot(df['prefix_count'], df['lookup_rate'] / 1e6, 's-', label='Lookup Rate (M ops/sec)')
    ax1.set_xscale('log')
    ax1.set_yscale('log')
    ax1.set_xlabel('Number of Prefixes')
    ax1.set_ylabel('Operations per Second (M ops/sec)')
    ax1.set_title('Performance Scaling with Prefix Count\nプレフィックス数に応じた性能スケーリング')
    ax1.grid(True)
    ax1.legend()
    
    # 2. メモリ使用量
    ax2.plot(df['prefix_count'], df['memory_usage_bytes'] / 1e6, 'o-', color='green')
    ax2.set_xscale('log')
    ax2.set_yscale('log')
    ax2.set_xlabel('Number of Prefixes')
    ax2.set_ylabel('Memory Usage (MB)')
    ax2.set_title('Memory Usage per Prefix Count\nプレフィックス数に応じたメモリ使用量')
    ax2.grid(True)
    
    # 3. マッチ率
    ax3.plot(df['prefix_count'], df['match_rate'], 'o-', color='purple')
    ax3.set_xscale('log')
    ax3.set_xlabel('Number of Prefixes')
    ax3.set_ylabel('Match Rate (%)')
    ax3.set_title('Match Rate vs Prefix Count\nプレフィックス数に応じたマッチ率')
    ax3.grid(True)
    
    plt.tight_layout(rect=[0, 0, 1, 0.96])  # タイトルのためのスペースを確保
    plt.savefig('assets/basic_benchmark.png', dpi=300, bbox_inches='tight')
    plt.close()

def plot_realistic_benchmark():
    """リアルタイムベンチマーク結果の可視化"""
    df = pd.read_csv('assets/realistic_bench_results.csv')
    
    # 図の作成
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 10))
    fig.suptitle('BART Realistic Benchmark Results\n実運用環境に近い性能評価', fontsize=16, y=0.98)
    
    # 1. パフォーマンスとメモリ使用量の関係
    ax1.plot(df['prefix_count'], df['lookup_rate'] / 1e6, 'o-', label='Lookup Rate (M ops/sec)')
    ax1_twin = ax1.twinx()
    ax1_twin.plot(df['prefix_count'], df['memory_usage_bytes'] / 1e6, 's-', color='red', label='Memory Usage (MB)')
    ax1.set_xscale('log')
    ax1.set_yscale('log')
    ax1.set_xlabel('Number of Prefixes')
    ax1.set_ylabel('Lookup Rate (M ops/sec)')
    ax1_twin.set_ylabel('Memory Usage (MB)')
    ax1.set_title('Performance and Memory Usage\n性能とメモリ使用量の関係')
    ax1.grid(True)
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax1_twin.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='upper left')
    
    # 2. キャッシュヒット率とマッチ率
    ax2.plot(df['prefix_count'], df['cache_hit_rate'], 'o-', label='Cache Hit Rate')
    ax2.plot(df['prefix_count'], df['match_rate'], 's-', label='Match Rate')
    ax2.set_xscale('log')
    ax2.set_xlabel('Number of Prefixes')
    ax2.set_ylabel('Rate (%)')
    ax2.set_title('Cache Hit Rate and Match Rate\nキャッシュヒット率とマッチ率')
    ax2.grid(True)
    ax2.legend()
    
    plt.tight_layout(rect=[0, 0, 1, 0.96])  # タイトルのためのスペースを確保
    plt.savefig('assets/realistic_benchmark.png', dpi=300, bbox_inches='tight')
    plt.close()

def plot_advanced_benchmark():
    """高度なベンチマーク結果の可視化"""
    df = pd.read_csv('assets/advanced_bench_results.csv')
    
    # 図の作成
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 10))
    fig.suptitle('BART Advanced Benchmark Results\nマルチスレッド性能評価', fontsize=16, y=0.98)
    
    # 1. スレッド数に応じたスケーラビリティ
    ax1.plot(df['thread_count'], df['lookup_rate'] / 1e6, 'o-', label='Lookup Rate (M ops/sec)')
    ax1.set_xlabel('Number of Threads')
    ax1.set_ylabel('Lookup Rate (M ops/sec)')
    ax1.set_title('Scalability with Thread Count\nスレッド数に応じたスケーラビリティ')
    ax1.grid(True)
    ax1.legend()
    
    # 2. メモリ断片化の影響
    ax2.plot(df['thread_count'], df['fragmentation_impact'], 'o-', color='red')
    ax2.set_xlabel('Number of Threads')
    ax2.set_ylabel('Fragmentation Impact (%)')
    ax2.set_title('Memory Fragmentation Impact\nメモリ断片化の影響')
    ax2.grid(True)
    
    plt.tight_layout(rect=[0, 0, 1, 0.96])  # タイトルのためのスペースを確保
    plt.savefig('assets/advanced_benchmark.png', dpi=300, bbox_inches='tight')
    plt.close()

def main():
    # assetsディレクトリの作成
    Path('assets').mkdir(exist_ok=True)
    
    # 各ベンチマークの結果をプロット
    plot_basic_benchmark()
    plot_realistic_benchmark()
    plot_advanced_benchmark()
    
    print("グラフの生成が完了しました。以下のファイルが作成されました：")
    print("- assets/basic_benchmark.png")
    print("- assets/realistic_benchmark.png")
    print("- assets/advanced_benchmark.png")

if __name__ == '__main__':
    main() 