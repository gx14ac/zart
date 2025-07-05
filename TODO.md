# ZART (Zig ART) - TODO List

## 実装すべき機能

### 1. 高度なLPM機能 ✅ 実装済み
- [x] LookupPrefixLPM: プレフィックス自体のLPM検索
- [x] Supernets: 指定プレフィックスの上位ネットワーク検索  
- [x] Subnets: 指定プレフィックスの下位ネットワーク検索

### 2. 不変性機能 ✅ 実装済み・修正済み
- [x] InsertPersist: 元のテーブルを変更せずに新しいテーブルを返す
- [x] UpdatePersist: 不変な更新操作
- [x] DeletePersist: 不変な削除操作
- [x] Clone: 完全なクローン機能
- [x] Child(V)のdeepCopyと所有権管理の修正 ✅
- [x] メモリリーク・二重解放の修正 ✅

### 3. オーバーラップ検出 ✅ 実装済み
- [x] Overlaps: 2つのテーブル間のオーバーラップ検出
- [x] OverlapsPrefix: 単一プレフィックスのオーバーラップ検出
- [x] Overlaps4/Overlaps6: IPv4/IPv6専用オーバーラップ検出

### 5. ユニオン操作
- [ ] Union: 2つのテーブルの結合

### 6. シリアライゼーション
- [ ] Fprint: 階層的なツリー表示
- [ ] MarshalJSON: JSON形式での出力
- [ ] DumpList4/DumpList6: 構造化されたリスト出力

### 7. Lite版
- [ ] Lite: ペイロードなしの軽量版（ACL用途）

### 8. ビットセット最適化 ✅ 部分的に実装済み
- [x] LPMルックアップテーブル: 事前計算されたバックトラッキングビットセット
- [x] idxToPrefixRoutes/idxToFringeRoutes: 事前計算されたプレフィックスルート ✅
- [ ] SIMD命令を使ったビットセット操作

### 9. パス圧縮 ✅ 実装済み
- [x] FringeNode: 特殊なパス圧縮ノード
- [x] LeafNode: リーフノードの最適化
- [x] isFringe: フリンジ判定ロジック

## 実装順序

1. ✅ LPMルックアップテーブル
2. ✅ 不変性機能
3. ✅ 高度な検索機能
4. ✅ パス圧縮の最適化
5. ✅ メモリ管理の修正（Child(V)のdeepCopyと所有権管理）
6. ✅ LPMテスト・サブネット検索テストの修正
7. ✅ integer overflowの修正（idxToPrefixRoutes/idxToFringeRoutes）
8. ✅ オーバーラップ検出
9. ユニオン操作
10. シリアライゼーション
11. Lite版
12. SIMD命令を使ったビットセット操作