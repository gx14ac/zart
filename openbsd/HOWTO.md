# OpenBSD + zart カーネル統合ガイド

## 概要

OpenBSDのART (Allotment Routing Table) をzartに置き換え、QEMUで動作確認する手順。

## アーキテクチャ

```
┌─────────────────────────────────────────────┐
│ OpenBSD Kernel                              │
│                                             │
│  rtable.c / if_wg.c                        │
│       │                                     │
│       ▼                                     │
│  zart_glue.c  (art API → zart C ABI)       │
│       │                                     │
│       ▼                                     │
│  zart_kernel.o (Zig freestanding, inlined)  │
│       │                                     │
│       ▼                                     │
│  KernelAllocator → malloc(9) M_RTABLE       │
└─────────────────────────────────────────────┘
```

## 手順

### 1. QEMU VM セットアップ (macOS側)

```bash
cd openbsd/
chmod +x setup-qemu.sh run-vm.sh deploy-zart.sh

# OpenBSD インストール (初回のみ)
./setup-qemu.sh

# インストール時に必ず comp76.tgz を含める (カーネルビルドに必要)
# sshd有効化、ユーザー dev 作成

# VM起動
./run-vm.sh
```

### 2. VM内でソースツリー取得

```bash
# SSH接続
ssh -p 2222 dev@localhost

# root になる
doas su -

# ソースツリー取得 (gx14ac fork)
cd /usr
cvs -d https://github.com/gx14ac/openbsd-src.git checkout -P src/sys
# または git clone
pkg_add git
cd /usr/src
git clone https://github.com/gx14ac/openbsd-src.git sys
```

### 3. zart デプロイ (macOS側)

```bash
cd /path/to/zart
./openbsd/deploy-zart.sh
```

### 4. カーネル統合 (VM内, root)

```bash
# zartファイル配置
cp ~/zart_kernel.o /usr/src/sys/net/
cp ~/zart.h /usr/src/sys/net/

# glueコード配置 (macOSから転送済みの場合)
# scp -P 2222 openbsd/zart_glue.c dev@localhost:
cp ~/zart_glue.c /usr/src/sys/net/

# 元のart.cをバックアップして置き換え
cd /usr/src/sys/net
cp art.c art.c.orig
cp zart_glue.c art.c  # art.cを完全にzart版に置換

# Makefileにzart_kernel.oを追加
# /usr/src/sys/conf/files に以下を追加:
#   file net/zart_kernel.o

# カーネルコンフィグ
cd /usr/src/sys/arch/amd64/conf
config GENERIC

# ビルド
cd /usr/src/sys/arch/amd64/compile/GENERIC
make clean && make

# カスタムカーネルインストール
cp obj/bsd /bsd.zart

# テスト起動
reboot
# boot プロンプトで: boot bsd.zart
```

### 5. 動作確認

```bash
# VM内でネットワーク確認
ifconfig
route -n show
ping 8.8.8.8

# ルート追加/削除テスト
route add 10.0.0.0/8 192.168.1.1
route delete 10.0.0.0/8
netstat -rn
```

## ファイル一覧

| ファイル | 説明 |
|---------|------|
| `setup-qemu.sh` | OpenBSD QEMUインストーラ起動 |
| `run-vm.sh` | VM通常起動 (SSH: port 2222) |
| `deploy-zart.sh` | .oとヘッダをVMに転送 |
| `zart_glue.c` | OpenBSD art API → zart C ABI ブリッジ |

## 既知の制限事項

- `art_insert` の戻り値 (replaced node) が未実装 → rtable.cのfree処理に影響する可能性
- `art_lookup` (exact match) がLPMにフォールバック → 正確なexact matchが必要な場合は要対応
- イテレータ (`art_iter_*`) が未実装 → `netstat -rn` 等が動かない可能性
- SMR (Safe Memory Reclamation) 未統合 → single-writer前提

## 次のステップ

1. art_iter実装 (テーブル走査)
2. art_insertのreplace戻り値対応
3. SMR統合 (atomic root swap + smr_call)
4. ベンチマーク (forwarding rate比較)
