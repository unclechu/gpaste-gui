let sources = import nix/sources.nix; in
{ pkgs ? import sources.nixpkgs {}
}:
let gpaste-gui = pkgs.callPackage ./. {}; in
pkgs.mkShell {
  buildInputs = [
    gpaste-gui
  ];
}
