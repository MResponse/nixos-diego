{
  fullName,
  mail,
  ...
}:

{
  programs.git = {
    enable = true;
    signing.format = "openpgp";
    settings.user.name = "${fullName}";
    settings.user.email = "${mail}";

    # Plan-0015 / ADR-0035: registriert den `ours`-merge-Driver als
    # no-op (exit 0), damit CLAUDE.md (per .gitattributes merge=ours)
    # bei `git merge master` unveraendert auf der diego-Seite bleibt.
    # Ohne diesen Eintrag warnt git: "merge driver 'ours' not found".
    settings.merge.ours.driver = "true";
  };
}
