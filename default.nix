let sources = import nix/sources.nix; in
{ callPackage
, perl
, perlPackages
, gnome3

# Overridable dependencies
, __nix-utils ? callPackage sources.nix-utils { inherit perlPackages; }

# Build options
, __name      ? "gpaste-gui"
, __srcScript ? builtins.readFile ./gpaste-gui.pl
}:
let
  inherit (__nix-utils)
    esc lines unlines writeCheckedExecutable wrapExecutableWithPerlDeps
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

  patchedScript =
    let
      reducer = acc: line:
        if ! isNull (builtins.match "^#!.*$" line) then (
          acc
        ) else if acc.state == "pre" then (
          let matches = builtins.match "^(my \\$gpaste_bin) = .*$" line; in
          if isNull matches
          then acc // { lines = acc.lines ++ [line]; }
          else {
            state = "in";
            lines = acc.lines ++ [
              "${builtins.elemAt matches 0} = q{${gpaste-client}};"
            ];
          }
        ) else if (acc.state == "in") then (
          if isNull (builtins.match "^[^ ].*;$" line)
          then acc
          else acc // { state = "post"; }
        ) else if (acc.state == "post") then (
          acc // { lines = acc.lines ++ [line]; }
        ) else throw "Unexpected state: ${acc.state}";

      initial = { lines = []; state = "pre"; };

      result = builtins.foldl' reducer initial (lines __srcScript);
    in
      assert result.state == "post";
      unlines result.lines;

  perlScript = writeCheckedExecutable __name checkPhase ''
    #! ${perl-exe}
    ${patchedScript}
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
