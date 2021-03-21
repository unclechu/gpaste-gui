# Author: Viacheslav Lotsmanov
# License: GNU/GPLv3 https://raw.githubusercontent.com/unclechu/gpaste-gui/master/LICENSE
let sources = import nix/sources.nix; in
{ pkgs ? import sources.nixpkgs {}
}:
let gpaste-gui = pkgs.callPackage ./. {}; in
pkgs.mkShell {
  buildInputs = [
    gpaste-gui
  ];
}
