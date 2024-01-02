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
          "virtio_pci"
          "overlay"
          # "virtio_blk"
        ];
        firmware = [ ];
      };

      paths = drv: pipe drv [
        (i: pkgs.closureInfo { rootPaths = i; })
        (i: "${i}/store-paths")
      ];

      preinit = with pkgs; writeScript "init" ''
        #!${busybox}/bin/sh
        PATH="${kmod}/bin:${busybox}/bin"
        echo "[1;32mWelcome to goblin!["

        log() { echo "[1;33m$*...[m"; }

        log "Loading kernel modules"
        modprobe -ad ${modules} 9p 9pnet_virtio virtio_pci overlay
        mkdir rootfs

        log "Mounting root filesystem"
        mount -t 9p -o trans=virtio rootfs rootfs

        log "Switching over"
        exec switch_root rootfs ${init}
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

      finish = with pkgs; writeScript "finish" ''
        #!${busybox}/bin/poweroff -f
      '';

      up = with pkgs; writeScriptBin "up" ''
        #!${busybox}/bin/sh
        awk '{printf "[1;32mUp after %s seconds![m\n", $1}' /proc/uptime
      '';

      invfork = pkgs.runCommandLocal "invfork"
        { nativeBuildInputs = with pkgs; [ gcc musl ]; }
        ''
          gcc -Wall -Wextra -O3 -static ${./invfork.c} -o $out
          strip $out
        '';

      svc = pkgs.runCommandLocal "svc" { } ''
        ${pkgs.s6-rc}/bin/s6-rc-compile $out ${./svc}
      '';

      init = with pkgs; writeScript "init" ''
        #!${execline}/bin/execlineb -P
        export PATH ${execline}/bin:${s6}/bin:${s6-rc}/bin:${up}/bin:${busybox}/bin
        foreground { sh -c "mount -t overlay -o lowerdir=$PATH,workdir=bin/work bin bin" }
        export PATH /bin
        foreground { echo "[1;33mStarting all services...[m" }
        foreground { mount -t tmpfs tmpfs /run  }
        foreground { mkdir -p /run/s6/scan/.s6-svscan }
        foreground { cp ${finish} /run/s6/scan/.s6-svscan/finish }
        ${invfork} { s6-svscan /run/s6/scan }
        foreground { s6-rc-init -c ${svc} -l /run/s6/live /run/s6/scan }
        foreground { s6-rc -l /run/s6/live start default }
      '';

      root = with pkgs; runCommandLocal "root" { } ''
        mkdir -p $out/{bin/work,dev,etc,proc,run,sys}
        cd $out

        mkdir -p nix/store
        xargs -I% cp -r % nix/store < ${paths init}

        echo 'root:x:0:0:System administrator:/:/bin/sh' > etc/passwd
        echo 'root:${builtins.readFile ./root.hash}:1::::::' | tr -d '\n' > etc/shadow
      '';

      # -drive id=disk,file=disk,if=none,format=raw
      # -device virtio-blk-pci,drive=disk
      boot = pkgs.writeShellScriptBin "boot" ''
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
      packages.${pkgs.system} = {
        inherit kernel preinit initrd root boot;
      };

      # devShells.${pkgs.system}.default = pkgs.mkShell {
      #   packages = with pkgs; [
      #     execline
      #     just
      #     qemu
      #     s6
      #     s6-portable-utils
      #     s6-rc
      #   ];
      # };
    };
}
