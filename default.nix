# Author: Viacheslav Lotsmanov
# License: GNU/GPLv3 https://raw.githubusercontent.com/unclechu/gpaste-gui/master/LICENSE

let sources = import nix/sources.nix; in
{ callPackage
, lib
, perl
, perlPackages
, gpaste

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
  gpaste-client = "${gpaste}/bin/gpaste-client";

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

  patchLines = startReg: endReg: replaceTo: srcLinse:
    assert builtins.isString startReg;
    assert builtins.isString endReg;
    assert builtins.isString replaceTo;
    let
      reducer = acc: line:
        if ! isNull (builtins.match "^#!.*$" line) then (
          acc
        ) else if acc.state == "pre" then (
          let matches = builtins.match startReg line; in
          if isNull matches
          then acc // { lines = acc.lines ++ [line]; }
          else { state = "in"; lines = acc.lines ++ [replaceTo]; }
        ) else if (acc.state == "in") then (
          if isNull (builtins.match endReg line)
          then acc
          else acc // { state = "post"; }
        ) else if (acc.state == "post") then (
          acc // { lines = acc.lines ++ [line]; }
        ) else throw "Unexpected state: ${acc.state}";

      result = builtins.foldl' reducer { lines = []; state = "pre"; } srcLinse;
    in
      assert result.state == "post";
      result.lines;

  patchedScript = lib.pipe __srcScript [
    lines
    (
      patchLines
        "^my \\$gpaste_bin = .*$"
        "^[^ ].*;$"
        "my $gpaste_bin = q{${gpaste-client}};"
    )
    (
      let version = builtins.splitVersion gpaste.version; in
      assert builtins.all (x: builtins.seq (lib.toInt x) true) version;
      patchLines
        "^my @gpaste_version = .*$"
        "^[^ ].*;$"
        "my @gpaste_version = (${builtins.concatStringsSep "," version});"
    )
    unlines
  ];

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
