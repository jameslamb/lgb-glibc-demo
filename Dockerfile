# pinning to specific version of ubuntu:22.04
FROM ubuntu@sha256:2a7dffab37165e8b4f206f61cfd984f8bb279843b070217f6ad310c9c31c9c7c

ENV CONDA=/root/miniforge \
    DEBIAN_FRONTEND=noninteractive \
    LANG="en_US.UTF-8" \
    LGB_COMMIT=416ecd5a8de1b2b9225ded3c919cb0d40ec0d9bd \
    LGB_SOURCE_DIR=/usr/local/src/LightGBM \
    PATH="/root/miniforge/bin:${PATH}" \
    PYTHON_VERSION=3.10

RUN apt-get update && \
    apt-get install \
        --no-install-recommends \
        -y \
            sudo && \
    sudo apt-get install \
        --no-install-recommends \
        -y \
            locales \
            software-properties-common && \
    sudo locale-gen ${LANG} && \
    sudo update-locale LANG=${LANG} && \
    sudo apt-get install \
        --no-install-recommends \
        -y \
            apt-utils \
            build-essential \
            ca-certificates \
            cmake \
            curl \
            git \
            iputils-ping \
            jq \
            libicu-dev \
            libcurl4 \
            libssl-dev \
            libunwind8 \
            locales \
            netcat \
            unzip \
            zip && \
    # install conda
    curl \
        -sL \
        -o miniforge.sh \
        https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh && \
    sh miniforge.sh -b -p ${CONDA} && \
    conda config --set always_yes yes --set changeps1 no && \
    conda update -q -y conda && \
    git clone \
        --recursive \
        https://github.com/microsoft/LightGBM.git \
        "${LGB_SOURCE_DIR}" && \
    cd "${LGB_SOURCE_DIR}" && \
    git checkout ${LGB_COMMIT}

WORKDIR "${LGB_SOURCE_DIR}"
