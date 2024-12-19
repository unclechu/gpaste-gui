# Author: Viacheslav Lotsmanov
# License: GNU/GPLv3 https://raw.githubusercontent.com/unclechu/gpaste-gui/master/LICENSE

let sources = import nix/sources.nix; in
{ pkgs ? import sources.nixpkgs {}
, perl-dependencies-in-dev-shell ? true
, use-system-gpaste-client ? false
}:
let gpaste-gui = pkgs.callPackage ./. {}; in
pkgs.mkShell {
  shellHook = pkgs.lib.optionalString perl-dependencies-in-dev-shell ''
    export PERL5LIB=${
      pkgs.lib.escapeShellArg
        (pkgs.perlPackages.makePerlPath gpaste-gui.perlDependencies)
    } || exit
  '';

  buildInputs =
    [ gpaste-gui ]
    ++ pkgs.lib.optional (! use-system-gpaste-client) pkgs.gpaste;
}
