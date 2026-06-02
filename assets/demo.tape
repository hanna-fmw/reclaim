# vhs tape for the reclaim demo GIF.
# Regenerate with:  vhs assets/demo.tape   (run from the repo root)
# Uses only leak-free commands (no real project paths shown).

Output assets/demo.gif

Set Shell bash
Set FontSize 15
Set Width 1100
Set Height 720
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

# Ensure the CLI is on PATH inside the recording shell (hidden from the GIF).
Hide
Type "export PATH=/opt/homebrew/bin:$PATH" Enter
Type "clear" Enter
Show

Type "reclaim help" Sleep 400ms Enter
Sleep 3s

Hide
Type "clear" Enter
Show

Type "reclaim doctor" Sleep 400ms Enter
Sleep 3500ms

Hide
Type "clear" Enter
Show

Type "reclaim status" Sleep 400ms Enter
Sleep 3s
