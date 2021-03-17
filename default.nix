let sources = import nix/sources.nix; in
{ callPackage
, perl
, gnome3
, perlPackages

# Overridable dependencies
, __nix-utils ? callPackage sources.nix-utils { inherit perlPackages; }

# Build options
, __name      ? "gpaste-gui"
, __srcScript ? builtins.readFile ./gpaste-gui.pl
}:
let
  inherit (__nix-utils)
    esc writeCheckedExecutable wrapExecutableWithPerlDeps
    shellCheckers valueCheckers;

  perl-exe = "${perl}/bin/perl";
  gpaste-client = "${gnome3.gpaste}/bin/gpaste-client";

  deps = p: [
    p.GetoptLong
    # p.PodUsage # ‘null’ dummy plug
    p.Glib
    p.Gtk2

    # Sub dependencies
    p.Pango
    p.Cairo
  ];

  checkPhase = ''
    ${shellCheckers.fileIsExecutable perl-exe}
    ${shellCheckers.fileIsExecutable gpaste-client}
  '';

  perlScript = writeCheckedExecutable __name checkPhase ''
    #! ${perl-exe}
    use v5.24; use strict; use warnings;
    $ENV{PATH} = q<${gnome3.gpaste}/bin:>.$ENV{PATH};
    ${__srcScript}
  '';
in
assert valueCheckers.isNonEmptyString __srcScript;
wrapExecutableWithPerlDeps "${perlScript}/bin/${__name}" {
  inherit deps checkPhase;
} // {
  inherit checkPhase;
  perlDependencies = deps perlPackages;
  srcScript = __srcScript;
}
