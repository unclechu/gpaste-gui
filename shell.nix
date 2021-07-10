# Author: Viacheslav Lotsmanov
# License: GNU/GPLv3 https://raw.githubusercontent.com/unclechu/gpaste-gui/master/LICENSE
let sources = import nix/sources.nix; in
{ pkgs ? import sources.nixpkgs {}
, providePerlDependenciesForDevShell ? true
}:
let gpaste-gui = pkgs.callPackage ./. {}; in
pkgs.mkShell {
  shellHook = if providePerlDependenciesForDevShell then ''
    export PERL5LIB=${
      pkgs.lib.escapeShellArg
        (pkgs.perlPackages.makePerlPath gpaste-gui.perlDependencies)
    } || exit
  '' else "";

  buildInputs = [
    gpaste-gui
  ];
}
