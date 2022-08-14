{ pkgs, ...}: pkgs.stdenv.mkDerivation {
  name = "vtrack-git";
  src = ../.;

  buildInputs = with pkgs; [sqlite];
  nativeBuildInputs = with pkgs; [gdc];
  buildPhase = ''
cd eudorina
sh ./build.sh
cd ../vtrack
sh ./build.sh
'';

  installPhase = ''
    mkdir "$out"
    mv build/bin "$out"/
  '';
}
