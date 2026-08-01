config.load_autoconfig(False)

c.window.transparent = True
c.colors.webpage.bg = "transparent"
c.colors.webpage.darkmode.enabled = True
c.content.user_stylesheets = ["~/.config/qutebrowser/styles/translucent-page.css"]

c.colors.hints.fg = "#000000"
c.colors.hints.bg = "#ffdf00"
c.colors.hints.match.fg = "#d00000"
c.hints.border = "2px solid #000000"
c.hints.padding = {"top": 2, "bottom": 2, "left": 6, "right": 6}
c.fonts.hints = "bold 12pt Iosevka"
