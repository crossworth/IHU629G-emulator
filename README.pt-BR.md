# IHU629G-emulator

[English](README.md) | **Português (Brasil)**

Emulador da central multimídia do **Geely EX2 vendido no Brasil**:
**ECARX E02 / IHU629G** com **Android 9 e Flyme Auto**, em um Mac
Apple Silicon usando QEMU com aceleração HVF. Usa um dump real do carro,
um kernel Linux 4.14 adaptado e substituições pontuais para executar o
firmware fora do hardware original.

![Flyme Auto no emulador IHU629G](assets/ihu629g-emulator.jpg)

Interface interativa, toque e adb disponíveis em cerca de **um minuto**
(68 s na verificação de 2026-10-19).

## Funciona

- Interface Flyme Auto em 1920×1080, com mouse/toque e teclado.
- Tela via VNC (`127.0.0.1:5901`, senha `ex2emu`) ou janela nativa do QEMU.
- adb root, diagnóstico de crashes e serviços ARM de 32 bits via qemu-arm.
- Simulação de propriedades do veículo: marcha, velocidade, bateria e dia/noite.
- Estado de carro estacionado e ajuste de relógio automáticos.

## Requisitos

- Mac **Apple Silicon** (HVF; não há caminho x86 aqui) com macOS atual.
- Homebrew: `qemu` (11.1 testado), `tmux`, `coreutils`; `adb` e `python3`.
- **Docker** - toda ferramenta Linux (debugfs, dtc,
  gcc-9, build do kernel) roda num container Ubuntu 20.04 arm64; o QEMU
  em si roda no host, nunca no container.
- ~60 GB livres + espaço para o dump.

## Firmware

**Firmware e dump não são distribuídos.** Você precisa fornecer um dump
válido da sua unidade Geely EX2 brasileira. As imagens originais são
somente leitura; as alterações e gravações do guest ficam em
`work/qemu/ex2.img`.

## Dump necessário e layout

O dump da unidade (leitura completa do eMMC) fica em `dump/` na raiz do
projeto (ignorado pelo git) ou no diretório indicado por `EX2_DUMP`:
**um arquivo raw por partição** (estilo dd; não Android sparse/simg, não
comprimido), nomeado `<partição>.img`. O stage de disco
(`tools/qemu/14_gpt.sh`) copia estas 46 partições:

```
proinfo nvram protect1 protect2 lk lk2 boot boot_para para recovery logo
expdb seccfg otp tee1 tee2 scp1 scp2 sspm_1 sspm_2 spmfw gz1 gz2 dtbo frp
nvcfg nvdata metadata persist pki private_ui vechilecfg system vendor
cache userdata mtkdata log md1img md1dsp md1arm7 md3img cam_vpu1 cam_vpu2
cam_vpu3 odmdtbo
```

Faltantes são pulados com aviso; **boot, system, vendor e userdata são
essenciais**. Além disso, copie `boot.img`, `system.img` e `vendor.img`
para `firmware/` (os stages 0/1/5 leem dali):

```sh
export EX2_DUMP="$PWD/dump"     # or an absolute path to your dump directory
mkdir -p firmware
cp -c "$EX2_DUMP"/{boot,system,vendor}.img firmware/ # cp -c: clone APFS, instantâneo
```

Um primeiro build também usa imagens GSI Android 9/API 28, um blob
gralloc extraído do seu dump e um blob redroid baixado do Docker Hub -
veja [Primeiro build](#primeiro-build) abaixo.
`run.sh` inicia o emulador já preparado; não constrói as imagens, e o
pipeline completo não foi reexecutado em um clone limpo nesta revisão.

## Uso rápido

```sh
./run.sh                       # boot + VNC + adb + VHAL baseline
./run.sh --cocoa               # janela nativa do QEMU em vez de VNC
./run.sh --status              # estado do guest
./run.sh --stop                # parada graciosa (sync do guest antes)

adb -s 127.0.0.1:5555 shell    # shell root
python3 tools/qemu/vhalctl.py setf 0x11600207 50   # 50 km/h
python3 tools/qemu/vhalctl.py set 0x2140800f 4     # marcha D (1=P 2=R 3=N)
```

Um guest por vez - o `run.sh` recusa iniciar enquanto outro guest está
em execução. Para trocar a exibição do guest em execução (ex.: de VNC
para a janela nativa do QEMU), pare-o antes:
`./run.sh --stop && ./run.sh --cocoa`.

## Primeiro build

<details>
<summary>Insumos que você precisa fornecer e a ordem completa dos stages</summary>

Tudo roda da raiz do projeto. O layout do dump e as cópias em
`firmware/` estão descritos acima; um primeiro build ainda precisa de:

- **Imagens GSI Android 9/API 28 arm64** (ext4 raw) em
  `work/android-sdk/system-28-raw.img` e
  `work/android-sdk/vendor-28-raw.img` - ex.: pacote SDK
  `system-images;android-28;default;arm64-v8a`; se a origem for uma
  Android sparse image, converta antes com `simg2img`.
- **`work/fw-gfx/gralloc.default.so`** - extraído do SEU dump (nenhum
  stage faz isso):

  ```sh
  tools/drun.sh -- bash -c \
    'mkdir -p /project/work/fw-gfx && debugfs -R \
     "dump /lib64/hw/gralloc.default.so /project/work/fw-gfx/gralloc.default.so" \
     /project/firmware/vendor.img'
  ```

- **Docker com rede** - `tools/02_blobs.sh` puxa
  `redroid/redroid:9.0.0-latest` do Docker Hub (SwiftShader, BT stub).

Ordem dos stages (a ordem importa; todos são idempotentes):

```sh
./tools/00_verify.sh && ./tools/01_meta.sh && ./tools/05_boot.sh
./tools/02_blobs.sh                 # redroid + GSI extraction, byte patches
./tools/qemu/10_kernel.sh           # ~8 min, native build in the container
./tools/qemu/12_dtb.sh              # DTB must match machine.sh (EX2_MEM!)
./tools/qemu/40_build_qemu_arm.sh   # qemu-arm with binder; BEFORE stage 13
./tools/qemu/13_ramdisk.sh
./tools/qemu/14_gpt.sh --force      # ~2 min, needs the dump
./tools/qemu/15_inject_swiftshader.sh
./tools/qemu/16_audio.sh
./tools/qemu/17_bluetooth.sh
./tools/qemu/18_adbd.sh
./tools/qemu/19_display.sh
./tools/qemu/21_aee_stub.sh         # stock crash dumps (tombstones)
./tools/qemu/22_usb_public_volume.sh
./tools/qemu/23_disable_omx.sh      # stops the OMX tombstone loop
./run.sh
```

</details>

## Segurança

Ambiente de pesquisa: **adb root sem autenticação, SELinux permissive e
dados da unidade original em userdata**. VNC, adb e VHAL ficam restritos
a `127.0.0.1`. Não exponha as portas nem publique seu dump ou disco de
trabalho.

## Limitações

- Sem saída de áudio real, câmeras/visão 360° ou display do painel.
- MCU/CAN e hardware do veículo não são reproduzidos; VHAL recebe valores simulados.
- Codecs de mídia/OMX e dependências MTK ION não funcionam integralmente.
- DRM/Widevine indisponível; há artefatos visuais conhecidos na barra de status.
- Validado apenas em macOS Apple Silicon; não há suporte x86.

Detalhes: [limitações conhecidas](BLOCKERS.md).
