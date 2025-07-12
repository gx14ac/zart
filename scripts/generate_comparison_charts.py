#!/usr/bin/env python3
"""
ZART vs Go BART Performance Comparison Chart Generator
"""

import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns
from pathlib import Path
import json

# Set style
plt.style.use('seaborn-v0_8')
sns.set_palette("husl")

def create_comparison_charts():
    """Create comprehensive comparison charts between ZART and Go BART"""
    
    # Performance data from benchmarks
    # Go BART results (ns/op) - from recent benchmark
    go_bart_data = {
        'Contains_IPv4': 5.578,
        'Lookup_IPv4': 17.45,
        'LookupPrefix_IPv4': 20.54,
        'LookupPfxLPM_IPv4': 23.06,
        'Contains_IPv6': 9.348,
        'Lookup_IPv6': 26.73,
        'LookupPrefix_IPv6': 20.55,
        'LookupPfxLPM_IPv6': 23.47,
        'Contains_IPv4_Miss': 12.21,
        'Lookup_IPv4_Miss': 16.26,
        'Contains_IPv6_Miss': 5.442,
        'Lookup_IPv6_Miss': 7.050,
    }
    
    # ZART results (ns/op) - from recent benchmark (MAJOR IMPROVEMENT!)
    zart_data = {
        'Contains_IPv4': 9.79,      # 🏆 MASSIVE IMPROVEMENT! (from 49.18 to 9.79)
        'Lookup_IPv4': 12.31,      # 🏆 MASSIVE IMPROVEMENT! (from 71.57 to 12.31)
        'LookupPrefix_IPv4': 24.60, # 🏆 MASSIVE IMPROVEMENT! (from 145.39 to 24.60)
        'LookupPfxLPM_IPv4': 22.17, # 🏆 MASSIVE IMPROVEMENT! (from 144.70 to 22.17)
        'Contains_IPv6': 2.87,      # 🏆 FASTER than Go BART! (from 12.21 to 2.87)
        'Lookup_IPv6': 5.13,       # 🏆 MASSIVE IMPROVEMENT! (from 17.47 to 5.13)
        'LookupPrefix_IPv6': 91.89, # 🏆 MASSIVE IMPROVEMENT! (from 378.34 to 91.89)
        'LookupPfxLPM_IPv6': 84.42, # 🏆 MASSIVE IMPROVEMENT! (from 300.39 to 84.42)
        'Contains_IPv4_Miss': 11.76, # 🏆 MASSIVE IMPROVEMENT! (from 108.81 to 11.76)
        'Lookup_IPv4_Miss': 17.84,  # 🏆 MASSIVE IMPROVEMENT! (from 135.87 to 17.84)
        'Contains_IPv6_Miss': 2.78,  # 🏆 FASTER than Go BART! (from 12.18 to 2.78)
        'Lookup_IPv6_Miss': 4.77,   # 🏆 MASSIVE IMPROVEMENT! (from 17.32 to 4.77)
    }
    
    # Create comparison chart
    fig, axes = plt.subplots(2, 2, figsize=(16, 12))
    fig.suptitle('ZART vs Go BART Performance Comparison\n(Lower is Better)', fontsize=16, fontweight='bold')
    
    # IPv4 Match Operations
    ipv4_match_ops = ['Contains', 'Lookup', 'LookupPrefix', 'LookupPfxLPM']
    go_bart_ipv4_match = [go_bart_data[f'{op}_IPv4'] for op in ipv4_match_ops]
    zart_ipv4_match = [zart_data[f'{op}_IPv4'] for op in ipv4_match_ops]
    
    x = np.arange(len(ipv4_match_ops))
    width = 0.35
    
    axes[0, 0].bar(x - width/2, go_bart_ipv4_match, width, label='Go BART', color='#2E86AB', alpha=0.8)
    axes[0, 0].bar(x + width/2, zart_ipv4_match, width, label='ZART', color='#A23B72', alpha=0.8)
    axes[0, 0].set_title('IPv4 Match Operations', fontweight='bold')
    axes[0, 0].set_ylabel('Time (ns/op)')
    axes[0, 0].set_xticks(x)
    axes[0, 0].set_xticklabels(ipv4_match_ops, rotation=45, ha='right')
    axes[0, 0].legend()
    axes[0, 0].grid(True, alpha=0.3)
    
    # IPv6 Match Operations
    ipv6_match_ops = ['Contains', 'Lookup', 'LookupPrefix', 'LookupPfxLPM']
    go_bart_ipv6_match = [go_bart_data[f'{op}_IPv6'] for op in ipv6_match_ops]
    zart_ipv6_match = [zart_data[f'{op}_IPv6'] for op in ipv6_match_ops]
    
    axes[0, 1].bar(x - width/2, go_bart_ipv6_match, width, label='Go BART', color='#2E86AB', alpha=0.8)
    axes[0, 1].bar(x + width/2, zart_ipv6_match, width, label='ZART', color='#A23B72', alpha=0.8)
    axes[0, 1].set_title('IPv6 Match Operations', fontweight='bold')
    axes[0, 1].set_ylabel('Time (ns/op)')
    axes[0, 1].set_xticks(x)
    axes[0, 1].set_xticklabels(ipv6_match_ops, rotation=45, ha='right')
    axes[0, 1].legend()
    axes[0, 1].grid(True, alpha=0.3)
    
    # Miss Operations Comparison
    miss_ops = ['Contains_IPv4_Miss', 'Lookup_IPv4_Miss', 'Contains_IPv6_Miss', 'Lookup_IPv6_Miss']
    miss_labels = ['Contains IPv4', 'Lookup IPv4', 'Contains IPv6', 'Lookup IPv6']
    go_bart_miss = [go_bart_data[op] for op in miss_ops]
    zart_miss = [zart_data[op] for op in miss_ops]
    
    x_miss = np.arange(len(miss_ops))
    axes[1, 0].bar(x_miss - width/2, go_bart_miss, width, label='Go BART', color='#2E86AB', alpha=0.8)
    axes[1, 0].bar(x_miss + width/2, zart_miss, width, label='ZART', color='#A23B72', alpha=0.8)
    axes[1, 0].set_title('Miss Operations', fontweight='bold')
    axes[1, 0].set_ylabel('Time (ns/op)')
    axes[1, 0].set_xticks(x_miss)
    axes[1, 0].set_xticklabels(miss_labels, rotation=45, ha='right')
    axes[1, 0].legend()
    axes[1, 0].grid(True, alpha=0.3)
    
    # Performance Ratio (ZART/Go BART)
    ratios = {}
    for key in go_bart_data:
        if key in zart_data:
            ratios[key] = zart_data[key] / go_bart_data[key]
    
    ratio_keys = list(ratios.keys())
    ratio_values = list(ratios.values())
    
    # Color code: green for better (< 1.0), yellow for acceptable (1.0-2.0), red for needs improvement (> 2.0)
    colors = ['#2E8B57' if r < 1.0 else '#FFD700' if r <= 2.0 else '#DC143C' for r in ratio_values]
    
    bars = axes[1, 1].bar(range(len(ratio_keys)), ratio_values, color=colors, alpha=0.8)
    axes[1, 1].axhline(y=1.0, color='black', linestyle='--', alpha=0.5, label='Parity Line')
    axes[1, 1].set_title('Performance Ratio (ZART/Go BART)', fontweight='bold')
    axes[1, 1].set_ylabel('Ratio (Lower is Better)')
    axes[1, 1].set_xticks(range(len(ratio_keys)))
    axes[1, 1].set_xticklabels([k.replace('_', '\n') for k in ratio_keys], rotation=45, ha='right', fontsize=8)
    axes[1, 1].legend()
    axes[1, 1].grid(True, alpha=0.3)
    
    # Add value labels on bars
    for bar, value in zip(bars, ratio_values):
        height = bar.get_height()
        axes[1, 1].text(bar.get_x() + bar.get_width()/2., height,
                       f'{value:.1f}x', ha='center', va='bottom', fontsize=8)
    
    plt.tight_layout()
    plt.subplots_adjust(top=0.93)
    
    # Save to assets directory
    output_path = Path('assets/zart_vs_go_bart_comparison.png')
    output_path.parent.mkdir(exist_ok=True)
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"Comparison chart saved to {output_path}")
    
    # Create summary table
    create_summary_table(go_bart_data, zart_data, ratios)
    
    # Don't show plots in headless environment
    # plt.show()

def create_summary_table(go_bart_data, zart_data, ratios):
    """Create a summary table with performance metrics"""
    
    fig, ax = plt.subplots(figsize=(12, 8))
    ax.axis('tight')
    ax.axis('off')
    
    # Prepare data for table
    operations = []
    go_bart_values = []
    zart_values = []
    ratio_values = []
    status = []
    
    for key in go_bart_data:
        if key in zart_data:
            operations.append(key.replace('_', ' '))
            go_bart_values.append(f"{go_bart_data[key]:.2f}")
            zart_values.append(f"{zart_data[key]:.2f}")
            ratio_values.append(f"{ratios[key]:.2f}x")
            
            if ratios[key] < 1.0:
                status.append("🏆 FASTER")
            elif ratios[key] <= 2.0:
                status.append("🥈 GOOD")
            else:
                status.append("🔴 NEEDS IMPROVEMENT")
    
    table_data = []
    for i in range(len(operations)):
        table_data.append([operations[i], go_bart_values[i], zart_values[i], ratio_values[i], status[i]])
    
    table = ax.table(cellText=table_data,
                    colLabels=['Operation', 'Go BART (ns/op)', 'ZART (ns/op)', 'Ratio', 'Status'],
                    cellLoc='center',
                    loc='center',
                    colWidths=[0.25, 0.15, 0.15, 0.15, 0.3])
    
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.scale(1.2, 1.5)
    
    # Style the table
    for i in range(len(operations) + 1):
        for j in range(5):
            cell = table[(i, j)]
            if i == 0:  # Header row
                cell.set_facecolor('#4CAF50')
                cell.set_text_props(weight='bold', color='white')
            else:
                if j == 4:  # Status column
                    if "FASTER" in table_data[i-1][j]:
                        cell.set_facecolor('#E8F5E8')
                    elif "GOOD" in table_data[i-1][j]:
                        cell.set_facecolor('#FFF8E1')
                    else:
                        cell.set_facecolor('#FFEBEE')
                else:
                    cell.set_facecolor('#F5F5F5' if i % 2 == 0 else 'white')
    
    plt.title('ZART vs Go BART Performance Summary\n(Using Real Routing Table: 1,062,046 prefixes)', 
              fontsize=14, fontweight='bold', pad=20)
    
    # Save summary table
    output_path = Path('assets/zart_vs_go_bart_summary.png')
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"Summary table saved to {output_path}")
    
    plt.close(fig)  # Close instead of show

def create_memory_comparison():
    """Create memory usage comparison chart"""
    
    # Memory data from benchmarks
    memory_data = {
        'Go BART': {
            'IPv4 (901,899 prefixes)': 15731,  # KBytes
            'IPv6 (160,147 prefixes)': 6070,   # KBytes
            'Total (1,062,046 prefixes)': 21799  # KBytes
        },
        'ZART': {
            # Note: ZART memory usage would need to be measured
            'IPv4 (901,899 prefixes)': 'N/A',
            'IPv6 (160,147 prefixes)': 'N/A',
            'Total (1,062,046 prefixes)': 'N/A'
        }
    }
    
    fig, ax = plt.subplots(figsize=(10, 6))
    
    categories = ['IPv4\n(901,899 prefixes)', 'IPv6\n(160,147 prefixes)', 'Total\n(1,062,046 prefixes)']
    go_bart_mem = [15731, 6070, 21799]
    
    x = np.arange(len(categories))
    width = 0.35
    
    bars1 = ax.bar(x - width/2, go_bart_mem, width, label='Go BART', color='#2E86AB', alpha=0.8)
    
    ax.set_title('Memory Usage Comparison', fontweight='bold')
    ax.set_ylabel('Memory Usage (KBytes)')
    ax.set_xticks(x)
    ax.set_xticklabels(categories)
    ax.legend()
    ax.grid(True, alpha=0.3)
    
    # Add value labels on bars
    for bar in bars1:
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
               f'{height:,} KB', ha='center', va='bottom')
    
    plt.tight_layout()
    
    # Save memory comparison
    output_path = Path('assets/memory_comparison.png')
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    print(f"Memory comparison saved to {output_path}")
    
    plt.close(fig)  # Close instead of show

if __name__ == "__main__":
    print("🚀 Generating ZART vs Go BART comparison charts...")
    create_comparison_charts()
    create_memory_comparison()
    print("✅ All comparison charts generated successfully!") 