package main

/*
#cgo CFLAGS: -I.
#cgo LDFLAGS: -L. -lbart
#include "bart.h"
*/
import "C"
import (
	"fmt"
)

func main() {
	// Create routing table with automatic cleanup
	tbl := C.bart_create()
	defer C.bart_destroy(tbl)

	// Example: IPv4 prefix insertion and lookup
	var ip4 C.uint32_t = 0xC0A80000   // 192.168.0.0
	C.bart_insert4(tbl, ip4, 16, 100) // Set value 100 for 192.168.0.0/16
	var found C.int
	result := C.bart_lookup4(tbl, C.uint32_t(0xC0A80101), &found) // Search for 192.168.1.1
	if found != 0 {
		fmt.Printf("Lookup IPv4: 0x%X -> value %d\n", 0xC0A80101, result)
	} else {
		fmt.Printf("Lookup IPv4: 0x%X not found\n", 0xC0A80101)
	}

	// Example: IPv6 prefix insertion and lookup
	ip6 := [16]C.uchar{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}   // 2001:db8:: (IPv6 prefix)
	C.bart_insert6(tbl, &ip6[0], 32, 200)                                            // Set value 200 for 2001:db8::/32
	addr6 := [16]C.uchar{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1} // 2001:db8:0:1::1
	result6 := C.bart_lookup6(tbl, &addr6[0], &found)
	if found != 0 {
		fmt.Printf("Lookup IPv6: 2001:db8:0:1::1 -> value %d\n", result6)
	} else {
		fmt.Printf("Lookup IPv6: 2001:db8:0:1::1 not found\n")
	}
}
