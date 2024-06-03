#!/bin/bash
#
# Script For Building Android arm64 Kernel
# Copyright (C) 2021-2026 itsshashanksp <9945shashank@gmail.com> & pure-soul-kk <krishnakripa34567@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#

set -e

# ── Colour helpers ──────────────────────────────────────────────────────────
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
green='\e[0;32m'

# ── Validate inputs (set via GHA env / workflow_dispatch) ───────────────────
ALLOWED_CODENAMES=("davinci" "phoenix" "sweet" "toco" "tucana" "violet")

if [[ -z "$DEVICE_TYPE" ]]; then
    echo -e "${red}Error: DEVICE_TYPE env variable is not set.${white}"
    exit 1
fi

if [[ ! " ${ALLOWED_CODENAMES[*]} " =~ " ${DEVICE_TYPE} " ]]; then
    echo -e "${red}Error: Invalid codename '$DEVICE_TYPE'. Allowed: ${ALLOWED_CODENAMES[*]}${white}"
    exit 1
fi

# ── Validate required secrets ───────────────────────────────────────────────
if [[ -z "$API_BOT" || -z "$CHATID" ]]; then
    echo -e "${red}Error: API_BOT and CHATID must be set as environment variables / secrets.${white}"
    exit 1
fi

# ── Device map ──────────────────────────────────────────────────────────────
declare -A DEVICE_NAMES=(
    [davinci]="REDMI K20 (OSS)"
    [phoenix]="REDMI K30 & POCO X2 (OSS)"
    [sweet]="REDMI NOTE 10 PRO (OSS)"
    [violet]="REDMI NOTE 7 PRO (OSS)"
    [toco]="TOCO"
    [tucana]="TUCANA"
)

DEVICE="${DEVICE_NAMES[$DEVICE_TYPE]}"
CODENAME="${DEVICE_TYPE^^}"   # uppercase

# ── Defconfigs ──────────────────────────────────────────────────────────────
DEFCONFIG_COMMON="vendor/sdmsteppe-perf_defconfig"
DEFCONFIG_DEVICE="vendor/${DEVICE_TYPE}.config"

# ── Kernel tag (fallback to date if not set) ────────────────────────────────
KERNEL_TAG="${KERNEL_TAG:-$(date '+%Y%m%d')}"

# ── AnyKernel3 ──────────────────────────────────────────────────────────────
AnyKernel="https://github.com/pure-soul-kk/AnyKernel3.git"
AnyKernelBranch="master"

# ── Build identity ──────────────────────────────────────────────────────────
export KBUILD_BUILD_HOST="sleeping-bag"
export KBUILD_BUILD_USER="puresoulkk"
export TZ=Asia/Kolkata
export ARCH=arm64
export SUBARCH=arm64
export HEADER_ARCH=arm64

# ── Telegram helpers ────────────────────────────────────────────────────────
BOT_MSG_URL="https://api.telegram.org/bot${API_BOT}/sendMessage"
BOT_BUILD_URL="https://api.telegram.org/bot${API_BOT}/sendDocument"
STICKER_ID="CAACAgIAAxkBAAFHPGBp3vv2alKfVBQ4v7AaHPF97GMSKAACGTEAArx_wUuGnBCRzvYJbTsE"

tg_sticker() {
    curl -s -X POST "https://api.telegram.org/bot${API_BOT}/sendSticker" \
        -d sticker="$STICKER_ID" \
        -d chat_id="$CHATID" > /dev/null
}

tg_post_msg() {
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$CHATID" \
        -d "parse_mode=Markdown" \
        -d text="$1" > /dev/null
}

tg_post_build() {
    local file="$1"
    local caption="$2"
    local SHA256CHECK
    SHA256CHECK=$(sha256sum "$file" | cut -d' ' -f1)
    curl --progress-bar -F document=@"$file" "$BOT_BUILD_URL" \
        -F chat_id="$CHATID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=Markdown" \
        -F caption="${caption} | *SHA256:* \`${SHA256CHECK}\`"
}

tg_error() {
    local file="$1"
    local caption="$2"
    curl --progress-bar -F document=@"$file" "$BOT_BUILD_URL" \
        -F chat_id="$CHATID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=Markdown" \
        -F caption="${caption} Failed to build — check error.log"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
echo -e "${green}<< cleanup >>${white}"
rm -rf out zip error.log

# ── Clang setup (Google prebuilt tarball) ────────────────────────────────────
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android16-qpr2-release/clang-r563880c.tar.gz"
CLANG_DIR="$HOME/clang"

echo -e "${green}<< fetching clang >>${white}"
if [[ ! -f "$CLANG_DIR/bin/clang" ]]; then
    mkdir -p "$CLANG_DIR"
    echo "Downloading clang tarball..."
    if ! curl -fL --retry 3 --retry-delay 5 -o /tmp/clang.tar.gz "$CLANG_URL"; then
        echo -e "${red}Error: Failed to download clang from Google. Check URL or network access.${white}"
        exit 1
    fi
    echo "Extracting clang..."
    # Google +archive tarballs have no top-level directory — extract directly into CLANG_DIR
    tar -xzf /tmp/clang.tar.gz -C "$CLANG_DIR"
    rm -f /tmp/clang.tar.gz
    if [[ ! -f "$CLANG_DIR/bin/clang" ]]; then
        echo -e "${red}Error: clang binary not found after extraction. Tarball structure may have changed.${white}"
        exit 1
    fi
fi
export PATH="$CLANG_DIR/bin:$PATH"
export KBUILD_COMPILER_STRING=$("$CLANG_DIR/bin/clang" --version \
    | head -n 1 \
    | perl -pe 's/\(http.*?\)//gs' \
    | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')

# ── Defconfig ───────────────────────────────────────────────────────────────
echo -e "${green}<< doing pre-compilation process >>${white}"
mkdir -p out
make clean && make mrproper

# Merge base + device defconfig in a single make invocation
make O=out ARCH=arm64 \
    "$DEFCONFIG_COMMON" \
    "$DEFCONFIG_DEVICE"

# ── Build ────────────────────────────────────────────────────────────────────
echo -e "${yellow}<< compiling the kernel >>${white}"
tg_sticker
tg_post_msg "⚙️ Triggered kernel build for *${DEVICE}* (\`${CODENAME}\`)"

Start=$(date +"%s")

make -j$(nproc --all) O=out \
    ARCH=arm64 \
    LLVM=1 \
    LLVM_IAS=1 \
    AR=llvm-ar \
    NM=llvm-nm \
    LD=ld.lld \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    STRIP=llvm-strip \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    2>&1 | tee error.log

End=$(date +"%s")
Diff=$(( End - Start ))

# ── Artifact paths ───────────────────────────────────────────────────────────
IMG="$PWD/out/arch/arm64/boot/Image.gz"
DTBO="$PWD/out/arch/arm64/boot/dtbo.img"
DTB="$PWD/out/arch/arm64/boot/dtb.img"

# ── Check build result ───────────────────────────────────────────────────────
if [[ ! -f "$IMG" ]]; then
    echo -e "${red}<< Build failed — check error.log >>${white}"
    tg_post_msg "❌ Kernel build failed for *${DEVICE}* (\`${CODENAME}\`) — uploading error log"
    tg_error "error.log" "❌"
    tg_post_msg "done"
    rm -rf out error.log
    exit 1
fi

echo -e "${green}<< Build completed in $(( Diff / 60 ))m $(( Diff % 60 ))s >>${white}"

# ── Package ──────────────────────────────────────────────────────────────────
echo -e "${green}<< cloning AnyKernel3 >>${white}"
git clone --depth=1 "$AnyKernel" --single-branch -b "$AnyKernelBranch" zip

cp "$IMG"  zip/
cp "$DTBO" zip/
cp "$DTB"  zip/

# Patch anykernel.sh device name
sed -i "s/device.name1=.*/device.name1=${DEVICE_TYPE}/" zip/anykernel.sh
sed -i "s/device.name2=.*/device.name2=${DEVICE_TYPE}in/" zip/anykernel.sh

echo -e "${yellow}<< making kernel zip >>${white}"
ZIP="LineageOS-${KERNEL_TAG}-${CODENAME}-$(date '+%Y%m%d-%H%M').zip"
(cd zip && zip -r9 "../$ZIP" . -x .git README.md LICENSE '*placeholder')

# ── Upload ───────────────────────────────────────────────────────────────────
tg_post_msg "✅ Kernel compiled for *${DEVICE}* in $(( Diff / 60 ))m $(( Diff % 60 ))s — uploading ZIP"
tg_post_build "$ZIP" "✅ *${DEVICE}* | \`${KERNEL_TAG}\`"
tg_post_msg "done"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf out zip error.log
