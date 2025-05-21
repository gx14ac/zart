#ifndef BART_H
#define BART_H

#include <stdint.h>
#ifdef __cplusplus
extern "C"
{
#endif

    // ルーティングテーブル構造体 (前方宣言)
    typedef struct BartTable BartTable;

    // テーブルの作成と破棄
    BartTable *bart_create(void);
    void bart_destroy(BartTable *table);

    // プレフィックスの挿入 (IPv4/IPv6版)
    // IPv4: ipはネットワークバイトオーダーの32bitアドレス, prefix_lenは長さ(0-32)
    int bart_insert4(BartTable *table, uint32_t ip, uint8_t prefix_len, uintptr_t value);
    // IPv6: addrは16バイトのアドレスバッファ, prefix_lenは長さ(0-128)
    int bart_insert6(BartTable *table, const uint8_t addr[16], uint8_t prefix_len, uintptr_t value);

    // ルックアップ (IPv4/IPv6版)
    // 見つかった場合はfoundに1がセットされ、最長一致の値を返す。見つからなければfoundに0がセットされ、戻り値は未定義(0)。
    uintptr_t bart_lookup4(BartTable *table, uint32_t ip, int *found);
    uintptr_t bart_lookup6(BartTable *table, const uint8_t addr[16], int *found);

#ifdef __cplusplus
}
#endif
#endif // BART_H