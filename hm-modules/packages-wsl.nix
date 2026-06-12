{ pkgs, ... }:

# WSL variant of packages.nix — keeps the CLI/LSP/editor tooling the Doom
# config actually shells out to, and DROPS the ~25 GUI/desktop/communication
# apps from the desktop packages.nix (discord, slack, teams, zoom, vscodium,
# anki, zotero, nemo, wofi, pavucontrol, warp-terminal, zed-editor, zeal,
# bruno, hyprpicker, imv, nsxiv, qolibri, signal/telegram/whatsapp/thunderbird,
# ...) which are useless inside a headless WSL editor box.

{
  home.packages = with pkgs; [
    # Search / CLI
    ripgrep-all
    television
    entr
    lnav
    jq
    yq-go
    glow
    btop
    ranger
    yt-dlp

    # Document tooling (org/markdown export, previews)
    graphviz
    pandoc
    mupdf
    poppler-utils
    csvlens

    # Reference
    cht-sh
    tldr

    # Dev / AI tooling Doom uses
    delta              # magit-delta
    claude-agent-acp   # agent-shell ACP backend
    wakatime-cli

    # Nix tooling
    nix-output-monitor
    nixfmt
    nixd               # Nix LSP

    # Tree-sitter grammars (Doom :tools tree-sitter)
    (tree-sitter.withPlugins (g: [
      g.tree-sitter-rust
      g.tree-sitter-haskell
      g.tree-sitter-python
      g.tree-sitter-bash
      g.tree-sitter-typst
    ]))

    # Writing & docs
    typst
    tinymist           # Typst LSP + preview
    # texlive.combined.scheme-medium  # re-enable for LaTeX / org-latex-preview (~1-2 GB)
    hunspell
    hunspellDicts.en_US
    hunspellDicts.de_DE
    vale
    proselint

    # Docker tooling (Doom :lang docker LSP/format)
    dockfmt
    dockerfile-language-server

    # Web dev formatters (Doom :lang web)
    html-tidy
    js-beautify
    stylelint

    # Japanese (emacs migemo/dict helpers)
    mecab
    kakasi
    cmigemo
  ];
}
