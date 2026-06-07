# Flux Frontend — 1-BOSQICH (MVP) misoli: view -> HTML string.
#
# `view` = komponent (fn'ning UI varianti). Tana element daraxti; chaqirilganda
# {__node} daraxti qaytaradi, `ui.html` uni SSR HTML stringga aylantiradi.
# Reaktivlik/server/source — keyingi bosqichlar.

# Oddiy komponent: ko'p elementli tana fragmentga yig'iladi.
view greeting name
  h1 "Salom $name"
  p "xush kelibsiz"

# Element bolalari indentatsiya orqali; semantik proplar ({kind:: pad:}) -> CSS class.
view card title price
  div {kind::panel pad:4}
    h2 title
    p "${price} so'm" {kind::muted}
    btn "Sotib olish" {kind::primary}

log (ui.html (greeting "Ali"))
log (ui.html (card "Atirgul" 50000))
