Original: TsudaKageyu/minhook v1.3.4, BSD license retained unchanged.
Original ZIP SHA256: 172708123daa0c98d20d3a980b16a50be14af243dc95dee6f79c24193ad010e4.

PBZ can reserve every allocation-granularity address within the usual relative
jump range. `MH_CreatePBZDamageHook` is a deliberately narrow fallback: it
accepts only the exact 20-byte, PC-independent TakeDamage prologue authenticated
by the caller's full executable digest. Its eight instruction boundaries were
decoded from the installed executable. It copies those bytes into a standalone
RX page, follows them with a 14-byte absolute jump back, and installs a 14-byte
absolute jump plus six padding bytes at the original entry. The upstream
freeze/unfreeze, thread-IP translation, protection, cache flush and restore paths
are retained. It is not an arbitrary-function relocation implementation.

Modified files: include/MinHook.h and src/hook.c. `absolutePBZ` allocations are
released on RemoveHook or Uninitialize. Production keeps its one disabled-or-enabled detour and
module pinned until process exit; Uninitialize is not called by that bridge.
