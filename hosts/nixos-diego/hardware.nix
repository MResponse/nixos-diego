{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    kernelPackages = pkgs.linuxPackages_latest;
    initrd = {
      availableKernelModules = [
        "nvme"
        "xhci_pci"
        "thunderbolt"
        "usb_storage"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    # mt7925e: the MediaTek MT7925 (14c3:7925) PCIe Wi-Fi half of the combo
    # chip intermittently fails to auto-load at boot — udev coldplug doesn't
    # fire the modalias, leaving ZERO mt7925e lines in dmesg, no wlan netdev
    # and the PCI device unbound (the Bluetooth half still comes up). A manual
    # `modprobe mt7925e` always loads it cleanly, so it's a load-timing flake,
    # not a firmware/device fault. Force-loading it here via systemd-modules-load
    # (runs well after PCI enumeration) makes Wi-Fi deterministic across boots.
    # Observed + fixed 2026-06-27.
    kernelModules = [ "kvm-amd" "mt7925e" ];
    extraModulePackages = [ ];
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/23a25bfa-fd95-4991-b8e2-43e1beb2f413";
      fsType = "btrfs";
      options = [ "subvol=@" ];
    };
    "/home" = {
      device = "/dev/disk/by-uuid/23a25bfa-fd95-4991-b8e2-43e1beb2f413";
      fsType = "btrfs";
      options = [ "subvol=@home" ];
    };
    "/boot" = {
      device = "/dev/disk/by-uuid/D617-F3A8";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/ff4b1460-fd56-4f17-b82a-63495487bd98"; }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware = {
    cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    enableRedistributableFirmware = true;
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
  };

  powerManagement.enable = true;
}
