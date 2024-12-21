{ inputs, cell }:
let
  inherit (inputs) nixpkgs nixpkgs-unstable;
in
import nixpkgs-unstable { inherit (nixpkgs) system; }
