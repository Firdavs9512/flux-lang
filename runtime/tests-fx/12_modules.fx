# 12 — Foydalanuvchi modullari: `use ./fayl`, `as alias`, eksport, closure,
# nested import, cache (issue #45). Yo'llar shu faylning katalogiga nisbatan.

fails <- 0

fn eq got want label
  if got == want
    log "ok  ${label} = ${got}"
  else
    log "FAIL ${label}: got=${got} want=${want}"
    fails <- fails + 1

# --- Asosiy import: exp qiymat va funksiya ---
use ./mod_math
eq mod_math.pi 3 "exp qiymat"
eq (mod_math.add 2 5) 7 "exp funksiya"

# --- Closure: modul fn modul-darajadagi private `base`ga kiradi ---
eq (mod_math.from_base 5) 105 "modul closure"

# --- Modul-private nom namespace'da yo'q ---
eq mod_math.base nil "private nom yashirin"

# --- as alias ---
use ./mod_math as m
eq (m.add 10 1) 11 "alias funksiya"

# --- Nested import: mod_nested -> mod_math ---
use ./mod_nested
eq (mod_nested.double 21) 42 "nested import"

# --- Cache: mod_math ikki marta use qilindi, bir xil namespace ---
eq mod_math.pi m.pi "cache — bir xil qiymat"

# --- par + modul import (issue #137 PR review): par lambda'lari alohida
# thread'da modul import qiladi. module_loading/current_base thread-local
# bo'lgani uchun parallel import soxta "sikllik import" bermaydi va base
# to'g'ri uzatiladi (nested-dir modul ham). Har ikki lambda {ok:...} qaytadi. ---
fn par_load n
  use ./mod_math
  ret mod_math.add n 1
prl = par [(\-> par_load 10) (\-> par_load 20)]
eq prl.0.ok 11 "par modul import 1"
eq prl.1.ok 21 "par modul import 2"

# --- Yakun ---
if fails == 0
  log "=== 12_modules: HAMMASI O'TDI ==="
else
  log "=== 12_modules: ${fails} TEST YIQILDI ==="
