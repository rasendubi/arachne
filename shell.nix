with import <nixpkgs> { };

haskell.lib.buildStackProject {
  name = "arachne";
  ghc = haskell.packages.ghc7103.ghc;
  buildInputs = [
    ncurses # For intero
    git # To enable git packages in stack.yaml
    cabal-install # For stack solver
    zlib
  ];
}
