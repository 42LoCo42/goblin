{
  outputs = { nixpkgs, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      inherit (pkgs.lib) pipe;

      kernel = pkgs.linux_latest;
      preModules = pkgs.makeModulesClosure {
        inherit kernel;
        firmware = [ ];
        rootModules = [
          "9p"
          "9pnet_virtio"
          "overlay"
          "virtio_pci"
        ];
      };
      modules = pkgs.makeModulesClosure {
        inherit kernel;
        firmware = [ ];
        rootModules = [
          "af_packet" # DHCP
          "virtio_net" # network access
        ];
      };

      paths = drv: "${pkgs.closureInfo { rootPaths = drv; }}/store-paths";

      # INITRD #################################################################

      tinit = pkgs.runCommandLocal "tinit"
        {
          src = ./tinit;
          nativeBuildInputs = with pkgs; [ gcc musl pkg-config ];
          buildInputs = with pkgs; [ (xz.override { enableStatic = true; }) ];
        } ''
        gcc                                     \
          -Wall -Wextra -Werror                 \
          -O3 -static -flto                     \
          $src/*.c                              \
          $(pkg-config --cflags --libs liblzma) \
          -lssp                                 \
          -o $out
        strip $out
      '';

      preinit = pkgs.writeScript "preinit" ''
        #!${tinit} ${preModules}/insmod-list
      '';

      initrd = pkgs.runCommandLocal "init-img"
        { nativeBuildInputs = with pkgs; [ cpio zstd ]; } ''
        img="$PWD/initrd.img"

        ln -s ${preinit} init
        mkdir -p nix/store
        printf '%s\n' init nix nix/store | cpio -H newc -oF $img

        xargs find < ${paths preinit} \
        | sed 's|/||'                 \
        | cpio -H newc -D/ -oAF $img

        zstd -9 < $img > $out
      '';

      # ROOT FILESYSTEM ########################################################

      path = pipe
        (with pkgs; [
          curl
          execline
          htop
          nix
          pciutils
          s6
          s6-rc
          (pkgs.writeScriptBin "s6" (builtins.readFile ./s6.sh)) # s6 helper

          busybox
        ]) [
        (map (i: "${i}/bin"))
        (builtins.concatStringsSep ":")
      ];

      svcDB = let svc = import ./svc.nix { inherit pkgs; }; in svc.mkDB rec {
        mount-bin = svc.oneshot {
          up = ''
            foreground { echo "[1;33mMounting bin overlay...[m" }
            foreground { mkdir -p /bin }
            mount -t overlay -o lowerdir=${path} bin /bin
          '';
        };

        mount-dev = svc.oneshot {
          up = ''
            foreground { mkdir -p /dev }
            mount -t devtmpfs dev /dev
          '';
          down = "umount -l /dev";
        };

        mount-devpts = svc.oneshot {
          up = ''
            foreground { mkdir -p /dev/pts }
            mount -t devpts devpts /dev/pts
          '';
          down = "umount -l /dev/pts";
          deps = { inherit mount-dev; };
        };

        mount-proc = svc.oneshot {
          up = ''
            foreground { mkdir -p /proc }
            mount -t proc proc /proc
          '';
          down = "umount -l /proc";
        };

        mount-sys = svc.oneshot {
          up = ''
            foreground { mkdir -p /sys }
            mount -t sysfs sys /sys
          '';
          down = "umount -l /sys";
        };

        mount-tmp = svc.oneshot {
          up = ''
            foreground { mkdir -p /tmp }
            mount -t tmpfs tmpfs /tmp
          '';
        };

        hostname = svc.oneshot {
          up = "hostname goblin";
        };

        load-modules = svc.oneshot {
          up = ''
            foreground { echo "[1;33mLoading additional kernel modules...[m" }
            redirfd -r 0 ${modules}/insmod-list
            xargs ${pkgs.kmod}/bin/modprobe -ad ${modules}
          '';
        };

        network = svc.longrun {
          run = "${pkgs.busybox}/bin/udhcpc -f";
          deps = { inherit hostname load-modules; };
        };

        getty-console = svc.longrun {
          run = "getty 115200 /dev/console";
          deps = { inherit mount-dev; };
          extra.down-signal = "SIGHUP";
        };

        nix-daemon = svc.longrun {
          run = "${pkgs.nix}/bin/nix daemon";
          deps = { inherit mount-tmp; };
        };

        dropbear = svc.longrun {
          run = "${pkgs.dropbear}/bin/dropbear -EFr /etc/dropbear.key";
          deps = { inherit mount-devpts; };
        };

        setup-etc-profile =
          let
            profile = pkgs.writeText "profile" ''
              export LANG="en_US.UTF8"
              export LOCALE_ARCHIVE=${pkgs.glibcLocalesUtf8}/lib/locale/locale-archive
            '';
          in
          svc.oneshot {
            up = "ln -s ${profile} /etc/profile";
          };

        setup-etc-ssl = svc.oneshot {
          up = ''
            foreground { mkdir -p /etc/ssl/certs }
            ln -sfT
              ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              /etc/ssl/certs/ca-certificates.crt
          '';
        };

        sysinit = svc.bundle {
          inherit mount-bin mount-dev mount-proc mount-sys hostname load-modules;
        };

        setup-etc = svc.bundle {
          inherit setup-etc-profile setup-etc-ssl;
        };

        daemons = svc.bundle {
          inherit getty-console nix-daemon dropbear network;
        };

        all = svc.bundle {
          inherit sysinit setup-etc daemons;
        };
      };

      poweroff-act = with pkgs; writeScript "poweroff" ''
        #!${execline}/bin/execlineb -P
        poweroff -f
      '';

      poweroff = with pkgs; writeScript "poweroff" ''
        #!${execline}/bin/execlineb -P
        foreground { ln -sfT ${poweroff-act} /run/s6/action }
        s6-svscanctl -t /run/s6/scan
      '';

      reboot-act = with pkgs; writeScript "reboot" ''
        #!${execline}/bin/execlineb -P
        reboot -f
      '';

      reboot = with pkgs; writeScript "reboot" ''
        #!${execline}/bin/execlineb -P
        foreground { ln -sfT ${reboot-act} /run/s6/action }
        s6-svscanctl -t /run/s6/scan
      '';

      finish = with pkgs; writeScript "finish" ''
        #!${execline}/bin/execlineb -P
        redirfd -a 1 /dev/console
        fdmove -c 2 1
        foreground { echo "\n[1;33mKilling all processes...[m" }
        foreground { kill -SIGKILL -1 }
        foreground { echo "[1;33mUnmounting filesystems...[m" }
        foreground { umount -rat nodevtmpfs,proc,tmpfs,sysfs }
        foreground { mount -o remount,ro / }
        foreground { sync }
        foreground { echo "[1;32mGoodbye![m" }
        /run/s6/action
      '';

      invfork = pkgs.runCommandLocal "invfork"
        { nativeBuildInputs = with pkgs; [ gcc musl ]; } ''
        gcc -Wall -Wextra -Werror -O3 -static -flto ${./invfork.c} -o $out
        strip $out
      '';

      init = pkgs.writeScript "init" ''
        #!${pkgs.execline}/bin/execlineb -P
        export PATH ${path}

        foreground { echo "[1;33mStarting the system supervisor...[m" }
        foreground { mount -t tmpfs tmpfs run }
        foreground { mkdir -p /run/s6/scan/.s6-svscan /run }
        foreground { ln -s ${poweroff} /run/s6/scan/.s6-svscan/SIGUSR2 }
        foreground { ln -s ${reboot}   /run/s6/scan/.s6-svscan/SIGTERM }
        foreground { ln -s ${finish}   /run/s6/scan/.s6-svscan/finish  }
        ${invfork} {
          redirfd -a 1 /run/s6/log
          fdmove -c 2 1
          s6-svscan /run/s6/scan
        }

        foreground { echo "[1;33mStarting all services...[m" }
        foreground { s6-rc-init -c ${svcDB} -l /run/s6/live /run/s6/scan }
        foreground { s6-rc -l /run/s6/live start all }

        awk "{printf \"\\e[1;32mUp after %s seconds!\\e[m\\n\", $1}" /proc/uptime
      '';

      root = with pkgs; runCommandLocal "root" { } ''
        mkdir -p $out/{nix/store,run}
        ln -s ${init} $out/init
        cp -r ${./etc} $out/etc
        xargs -I% cp -r % $out/nix/store < ${paths init}
      '';

      # -drive id=disk,file=disk,if=none,format=raw
      # -device virtio-blk-pci,drive=disk
      boot = pkgs.writeShellScript "boot" ''
        ${pkgs.qemu}/bin/qemu-system-x86_64                               \
          -enable-kvm                                                     \
          -smp 4                                                          \
          -m 8G                                                           \
          -cpu host                                                       \
          -nographic                                                      \
          -device virtio-keyboard                                         \
          -virtfs local,path=${root},mount_tag=rootfs,security_model=none \
          -netdev user,id=net0,hostfwd=tcp::2222-:22                      \
          -device virtio-net-pci,netdev=net0                              \
          -kernel ${kernel}/bzImage                                       \
          -initrd ${initrd}                                               \
          -append "console=ttyS0 panic=5 loglevel=4"
      '';
    in
    {
      apps.${pkgs.system}.default = {
        type = "app";
        program = "${boot}";
      };

      packages.${pkgs.system} = {
        inherit tinit initrd root kernel;
      };
    };
}
