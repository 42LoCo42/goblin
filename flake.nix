{
  outputs = { nixpkgs, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      inherit (pkgs.lib) pipe;

      kernel = pkgs.linux_latest;
      modules = pkgs.makeModulesClosure {
        inherit kernel;
        rootModules = [
          "9p"
          "9pnet_virtio"
          "overlay"
          "virtio_net"
          "virtio_pci"
        ];
        firmware = [ ];
      };

      paths = drv: "${pkgs.closureInfo { rootPaths = drv; }}/store-paths";

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
        #!${tinit} ${modules}/insmod-list
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

      poweroff = with pkgs; writeScript "poweroff" ''
        #!${execline}/bin/execlineb -P
        kill -SIGTERM 1
      '';

      finish = with pkgs; writeScript "finish" ''
        #!${execline}/bin/execlineb -P
        foreground { echo "\n[1;33mKilling all processes...[m" }
        foreground { kill -SIGKILL -1 }
        foreground { echo "[1;33mUnmounting filesystems...[m" }
        foreground { umount -rat nodevtmpfs,proc,tmpfs,sysfs }
        foreground { mount -o remount,ro / }
        foreground { sync }
        foreground { echo "[1;32mGoodbye![m" }
        poweroff -f
      '';

      invfork = pkgs.runCommandLocal "invfork"
        { nativeBuildInputs = with pkgs; [ gcc musl ]; } ''
        gcc -Wall -Wextra -Werror -O3 -static -flto ${./invfork.c} -o $out
        strip $out
      '';

      svc = import ./svc.nix { inherit pkgs; };
      svcDB = svc.mkDB rec {
        mount-dev = svc.oneshot {
          up = ''
            foreground { mkdir -p /dev }
            mount -t devtmpfs dev /dev
          '';
        };

        mount-devpts = svc.oneshot {
          up = ''
            foreground { mkdir -p /dev/pts }
            mount -t devpts devpts /dev/pts
          '';
          deps = { inherit mount-dev; };
        };

        mount-proc = svc.oneshot {
          up = ''
            foreground { mkdir -p /proc }
            mount -t proc proc /proc
          '';
        };

        mount-sys = svc.oneshot {
          up = ''
            foreground { mkdir -p /sys }
            mount -t sysfs sys /sys
          '';
        };

        hostname = svc.oneshot {
          up = "hostname goblin";
        };

        network = svc.oneshot {
          up = ''
            foreground { ip link set dev eth0 up }
            foreground { ip addr add dev eth0 192.168.122.42/24 }
            foreground { ip route add default via 192.168.122.1 }
          '';
        };

        getty-console = svc.longrun {
          run = "getty 115200 /dev/console";
          deps = { inherit mount-dev hostname; };
          extra.down-signal = "SIGHUP";
        };

        nix-daemon = svc.longrun {
          run = ''
            redirfd -a 1 /run/nix-daemon.log
            fdmove -c 2 1
            ${pkgs.nix}/bin/nix daemon
          '';
        };

        dropbear = svc.longrun {
          run = "${pkgs.dropbear}/bin/dropbear -EFr /etc/dropbear.key";
          deps = { inherit mount-devpts; };
        };

        link-modules = svc.oneshot {
          up = "ln -sfT ${modules}/lib /lib";
        };

        sysinit = svc.bundle {
          inherit mount-dev mount-proc mount-sys hostname network;
        };

        all = svc.bundle {
          inherit sysinit getty-console nix-daemon dropbear link-modules;
        };
      };

      path = pipe
        (with pkgs; [
          curl
          execline
          nix
          pciutils
          s6
          s6-rc

          busybox
        ]) [
        (map (i: "${i}/bin"))
        (builtins.concatStringsSep ":")
      ];

      profile = pkgs.writeText "profile" ''
        export CURL_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      '';

      init = pkgs.writeScript "init" ''
        #!${pkgs.execline}/bin/execlineb -P
        export PATH ${path}

        foreground { echo "[1;33mMaking / writeable...[m" }
        foreground { mount -t tmpfs tmpfs /run }
        foreground { mkdir -p /run/mnt /run/rw /run/wk }
        foreground { mount -t overlay -o lowerdir=/,upperdir=/run/rw,workdir=/run/wk rootfs /run/mnt }
        chroot /run/mnt

        foreground { ln -s ${profile} /etc/profile }

        foreground { echo "[1;33mMounting bin overlay...[m" }
        foreground { mkdir bin }
        foreground { sh -c "mount -t overlay -o lowerdir=$PATH bin bin" }
        export PATH /bin

        foreground { echo "[1;33mStarting the system supervisor...[m" }
        foreground { mount -t tmpfs tmpfs run }
        foreground { mkdir -p /run/s6/scan/.s6-svscan }
        foreground { ln -s ${poweroff} /run/s6/scan/.s6-svscan/SIGUSR2 }
        foreground { ln -s ${finish}   /run/s6/scan/.s6-svscan/finish  }
        ${invfork} { s6-svscan /run/s6/scan }

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
          -m 1G                                                           \
          -cpu host                                                       \
          -nographic                                                      \
          -no-reboot                                                      \
          -virtfs local,path=${root},mount_tag=rootfs,security_model=none \
          -kernel ${kernel}/bzImage                                       \
          -initrd ${initrd}                                               \
          -append "console=ttyS0 panic=-1 loglevel=4"
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
