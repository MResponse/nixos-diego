{ ... }:

# Tailscale — join Marius's WireGuard mesh so diego can reach the other NixOS
# hosts (today: xardas) from ANY network, without opening a single port to the
# internet. This is the canonical 8-line module documented in
# shared-claude/Infrastruktur/Tailscale/ARCHITECTURE.md §2 — enable the daemon
# and trust the mesh interface, nothing more. Deliberately NOT set:
#   - services.tailscale.useRoutingFeatures (no subnet router, no exit node)
#   - Funnel / Serve (never expose anything to the public internet)
#   - ACL tags (default tailnet ACL: every node of the tailnet reaches every
#     other node)
#
# WHY now: shared-claude/Infrastruktur/Tailscale/adr/0005 ("module loaded but
# no nodes registered") parked the whole tailnet as a deliberate YAGNI — the
# module was held on the old host generation but NO node ever logged in,
# because there was no concrete use-case. ADR-0005 lists the exact triggers to
# flip it on; "SSH between devices" is one of them. So activating here is the
# documented plan, not a deviation. (This ZBook is a fresh diego that never had
# the module at all, so this adds it from scratch.)
#
# WHAT this does and does NOT do at rebuild time: it starts the `tailscaled`
# daemon and creates the `tailscale0` interface — but it does NOT join any
# tailnet on its own. Per shared-claude/Infrastruktur/Tailscale/adr/0004 auth
# is manual: after the rebuild you run, ONCE, interactively:
#       sudo tailscale up
# open the printed URL, log in with the account that owns the tailnet, done.
# Verify the right tailnet with `tailscale status` (name shown at the top).
#
# Laptop caveat: Tailscale expires node keys after ~180 days (ADR-0004); a
# laptop will occasionally need a re-`up`. `tailscale status` shows "key
# expired" when that day comes.
#
# Revert: delete this file, drop the `./tailscale.nix` import from
# hosts/nixos-diego/default.nix, then `sudo tailscale logout` and rebuild.
{
  services.tailscale.enable = true;

  # Trust the encrypted mesh interface wholesale. Consequence (by design, see
  # shared-claude/Infrastruktur/Tailscale/adr/0003): any daemon NOT explicitly
  # bound to 127.0.0.1 becomes reachable from Marius's own devices over the
  # tailnet, while every non-tailnet interface stays strict default-deny. The
  # model is "localhost-only OR all-my-devices — nothing in between." On a
  # laptop diego mostly acts as the SSH *client*, so this is forward-looking
  # (lets xardas/relay reach back) rather than strictly required today.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
