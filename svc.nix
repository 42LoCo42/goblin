{ pkgs }: rec {
  inherit (pkgs.lib) mapAttrsToList pipe;

  oneshot = { deps ? { }, up, down ? "", extra ? { } }: service {
    type = "oneshot";
    inherit deps;
    extra = extra // { inherit up; } //
      (if down != "" then { inherit down; } else { });
  };

  longrun = { deps ? { }, run, extra ? { } }: service {
    type = "longrun";
    inherit deps;
    extra = extra // { run = "#!${pkgs.execline}/bin/execlineb -P\n" + run; };
  };

  service = { type, deps, extra }: ''
    echo ${type} > type
    ${if deps != {} then "mkdir dependencies.d" else ""}
  '' + pipe deps [
    (builtins.attrNames)
    (map (i: "touch dependencies.d/${i}"))
    (builtins.concatStringsSep "\n")
  ] + "\n" + pipe extra [
    (mapAttrsToList (name: text: ''
      cp ${pkgs.writeText name (text + "\n")} ${name}
    ''))
    (builtins.concatStringsSep "\n")
  ];

  bundle = deps: ''
    echo bundle > type
    mkdir contents.d
  '' + pipe deps [
    (builtins.attrNames)
    (map (i: "touch contents.d/${i}"))
    (builtins.concatStringsSep "\n")
  ];

  mkDB = services: pipe services [
    (mapAttrsToList (name: cmd: ''
      mkdir ${name}
      cd ${name}
      ${cmd}
      cd ..
    ''))
    (builtins.concatStringsSep "\n")
    (i: ''
      mkdir svc
      cd svc
      ${i}
      cd ..
      ${pkgs.s6-rc}/bin/s6-rc-compile $out svc
    '')
    (pkgs.runCommand "mkDB" { })
  ];
}
