#!/usr/bin/env bash

# The following environment variables are required:
SHARED=${SHARED:-OFF}
NPROC=${NPROC:-$(getconf _NPROCESSORS_ONLN)}    # POSIX: MacOS + Linux
if [ -z "${BUILD_CUDA_MODULE:+x}" ] ; then
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        BUILD_CUDA_MODULE=ON
    else
        BUILD_CUDA_MODULE=OFF
    fi
fi
BUILD_TENSORFLOW_OPS=${BUILD_TENSORFLOW_OPS:-ON}
BUILD_PYTORCH_OPS=${BUILD_PYTORCH_OPS:-ON}
if [[ "$OSTYPE" == "linux-gnu"* ]] && [ "$BUILD_CUDA_MODULE" == OFF ] ; then
    BUILD_PYTORCH_OPS=OFF   # PyTorch Ops requires CUDA + CUDNN to build
fi
BUILD_RPC_INTERFACE=${BUILD_RPC_INTERFACE:-ON}
LOW_MEM_USAGE=${LOW_MEM_USAGE:-OFF}
BUILD_WHEEL_ONLY=${BUILD_WHEEL_ONLY:=OFF}

# Dependency versions
CUDA_VERSION=("10-1" "10.1")
CUDNN_MAJOR_VERSION=7
CUDNN_VERSION="7.6.5.32-1+cuda10.1"
TENSORFLOW_VER="2.3.0"
TORCH_GLNX_VER=("1.6.0+cu101" "1.6.0+cpu")
TORCH_MACOS_VER="1.6.0"
YAPF_VER="0.30.0"

OPEN3D_INSTALL_DIR=~/open3d_install

rj_startts=${rj_startts:-$(date +%s)}
rj_prevts=${rj_prevts:-$rj_startts}
rj_prevj=${rj_prevj:-ReportInit}

reportJobStart() {
    rj_ts=$(date +%s)
    ((rj_dt = rj_ts - rj_prevts)) || true
    echo "$rj_ts EndJob $rj_prevj ran for $rj_dt sec (session started $rj_startts)"
    echo "$rj_ts StartJob $1"
    rj_prevj=$1
    rj_prevts=$rj_ts
}

reportJobFinishSession() {
    rj_ts=$(date +%s)
    ((rj_dt = rj_ts - rj_prevts)) || true
    echo "$rj_ts EndJob $rj_prevj ran for $rj_dt sec (session started $rj_startts)"
    ((rj_dt = rj_ts - rj_startts)) || true
    echo "ReportJobSession: ran for $rj_dt sec"
}

reportRun() {
    reportJobStart "$*"
    echo "path: $(which "$1")"
    "$@"
}

install_cuda_toolkit() {

    echo "Installing CUDA ${CUDA_VERSION[1]} with apt ..."
    sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub
    sudo apt-add-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64 /"
    sudo apt-get install --yes "cuda-toolkit-${CUDA_VERSION[0]}"
    if [ "${CUDA_VERSION[1]}" == "10.1" ]; then
        echo "CUDA 10.1 needs CUBLAS 10.2. Symlinks ensure this is found by cmake"
        dpkg -L libcublas10 libcublas-dev | while read -r cufile ; do
            if [ -f "$cufile" ] && [ ! -e "${cufile/10.2/10.1}" ] ; then
                set -x
                sudo ln -s "$cufile" "${cufile/10.2/10.1}"
                set +x
            fi
        done
    fi
    options="$(echo "$@" | tr ' ' '|')"
    set +u  # Disable "unbound variable is error" since that gives a false alarm error below:
    if [[ "with-cudnn" =~ ^($options)$ ]] ; then
        echo "Installing cuDNN ${CUDNN_VERSION} with apt ..."
        sudo apt-add-repository "deb https://developer.download.nvidia.com/compute/machine-learning/repos/ubuntu1804/x86_64 /"
        sudo apt-get install --yes \
            "libcudnn${CUDNN_MAJOR_VERSION}=$CUDNN_VERSION" \
            "libcudnn${CUDNN_MAJOR_VERSION}-dev=$CUDNN_VERSION"
    fi
    CUDA_TOOLKIT_DIR=/usr/local/cuda-${CUDA_VERSION[1]}
    export PATH="${CUDA_TOOLKIT_DIR}/bin${PATH:+:$PATH}"
    export LD_LIBRARY_PATH="${CUDA_TOOLKIT_DIR}/extras/CUPTI/lib64:$CUDA_TOOLKIT_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo PATH="$PATH"
    echo LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
    if [[ "purge-cache" =~ ^($options)$ ]] ; then
        sudo apt-get clean
        sudo rm -rf /var/lib/apt/lists/*
    fi
    set -u
}


install_python_dependencies() {

    python -m pip install --upgrade pip
    python -m pip install -U wheel
    options="$(echo "$@" | tr ' ' '|')"
    if [[ "with-unit-test" =~ ^($options)$ ]] ; then
        python -m pip install -U pytest
        python -m pip install scipy
    fi
    if [[ "with-cuda" =~ ^($options)$ ]] ; then
        TF_ARCH_NAME=tensorflow-gpu
        TF_ARCH_DISABLE_NAME=tensorflow-cpu
        TORCH_ARCH_GLNX_VER=${TORCH_GLNX_VER[0]}
    else
        TF_ARCH_NAME=tensorflow-cpu
        TF_ARCH_DISABLE_NAME=tensorflow-gpu
        TORCH_ARCH_GLNX_VER=${TORCH_GLNX_VER[0]}
    fi

    echo
    date
    if [ "$BUILD_TENSORFLOW_OPS" == "ON" ]; then
        # TF happily installs both CPU and GPU versions at the same time, so remove the other
        reportRun python -m pip uninstall --yes "$TF_ARCH_DISABLE_NAME"
        reportRun python -m pip install -U "$TF_ARCH_NAME"=="$TENSORFLOW_VER"
    fi
    if [ "$BUILD_PYTORCH_OPS" == "ON" ]; then
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            reportRun python -m pip install -U torch=="$TORCH_ARCH_GLNX_VER" -f https://download.pytorch.org/whl/torch_stable.html
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            reportRun python -m pip install -U torch=="$TORCH_MACOS_VER"
        else
            echo "unknown OS $OSTYPE"
            exit 1
        fi
    fi
    if [ "$BUILD_TENSORFLOW_OPS" == "ON" ] || [ "$BUILD_PYTORCH_OPS" == "ON" ]; then
        reportRun python -m pip install -U yapf=="$YAPF_VER"
    fi
    if [[ "purge-cache" =~ ^($options)$ ]] ; then
        echo "Purge pip cache"
        python -m pip cache purge 2>/dev/null || true
    fi
}


build_all() {

    mkdir -p build
    cd build

    cmakeOptions=(-DBUILD_SHARED_LIBS="$SHARED" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_CUDA_MODULE="$BUILD_CUDA_MODULE" \
        -DCUDA_ARCH=BasicPTX \
        -DBUILD_TENSORFLOW_OPS="$BUILD_TENSORFLOW_OPS" \
        -DBUILD_PYTORCH_OPS="$BUILD_PYTORCH_OPS" \
        -DBUILD_RPC_INTERFACE="$BUILD_RPC_INTERFACE" \
        -DCMAKE_INSTALL_PREFIX="$OPEN3D_INSTALL_DIR" \
        -DPYTHON_EXECUTABLE="$(which python)" \
        -DBUILD_UNIT_TESTS=ON \
        -DBUILD_BENCHMARKS=ON \
        -DBUILD_EXAMPLES=OFF \
    )

    echo
    echo Running cmake "${cmakeOptions[@]}" ..
    reportRun cmake "${cmakeOptions[@]}" ..
    echo
    echo "build & install Open3D..."
    date
    reportRun make VERBOSE=1 -j"$NPROC"
    reportRun make install -j"$NPROC"
    reportRun make VERBOSE=1 install-pip-package -j"$NPROC"
    echo
}


build_wheel() {

    echo
    echo Building with CPU only...
    date
    mkdir -p build
    cd build         # PWD=Open3D/build

    # BUILD_FILAMENT_FROM_SOURCE if Linux and old glibc (Ubuntu 18.04)
    BUILD_FILAMENT_FROM_SOURCE=OFF
    if [ "$OSTYPE" == "linux-gnu*" ] ; then
        glibc_version=$(ldd --version | grep -o -E '([0-9]+\.)+[0-9]+' | head -1)
        if dpkg --compare-versions "$glibc_version" lt 2.31 ; then
            BUILD_FILAMENT_FROM_SOURCE=ON
        fi
    fi

    cmakeOptions=(-DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TENSORFLOW_OPS=ON \
        -DBUILD_PYTORCH_OPS=ON \
        -DBUILD_RPC_INTERFACE=ON \
        -DBUILD_FILAMENT_FROM_SOURCE="$BUILD_FILAMENT_FROM_SOURCE" \
        -DBUILD_JUPYTER_EXTENSION=ON \
        -DCMAKE_INSTALL_PREFIX="$OPEN3D_INSTALL_DIR" \
        -DPYTHON_EXECUTABLE="$(which python)" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_UNIT_TESTS=OFF \
        -DBUILD_BENCHMARKS=OFF \
    )
    reportRun cmake -DBUILD_CUDA_MODULE=OFF "${cmakeOptions[@]}" ..
    echo
    reportRun make VERBOSE=1 -j"$NPROC" pybind open3d_tf_ops open3d_torch_ops

    if [ "$BUILD_CUDA_MODULE" == ON ] ; then
        echo
        echo Installing CUDA versions of Tensorflow and PyTorch...
        install_python_dependencies with-cuda purge-cache
        echo
        echo Building with CUDA...
        date
        rebuild_list=(bin lib/Release/*.a  lib/_build_config.py cpp lib/ml)
        echo
        echo Removing CPU compiled files / folders: "${rebuild_list[@]}"
        rm -r "${rebuild_list[@]}" || true
        reportRun cmake -DBUILD_CUDA_MODULE=ON -DCUDA_ARCH=BasicPTX "${cmakeOptions[@]}" ..
    fi
    echo
    echo "Building Open3D wheel..."
    date
    reportRun make VERBOSE=1 -j"$NPROC" pip-package
}

install_wheel() {
    echo
    echo "Installing Open3D wheel..."
    date
    reportRun python -m pip install open3d -f lib/python_package/pip_package/
}

test_wheel() {
    reportRun python -c "import open3d; print('Installed:', open3d)"
    reportRun python -c "import open3d; open3d.pybind.core.kernel.test_mkl_integration()"
    reportRun python -c "import open3d; print('CUDA enabled: ', open3d.core.cuda.is_available())"
    if [ "$BUILD_PYTORCH_OPS" == ON ] ; then
        reportRun python -c \
            "import open3d.ml.torch; print('PyTorch Ops library loaded:', open3d.ml.torch._loaded)"
    fi
    if [ "$BUILD_TENSORFLOW_OPS" == ON ] ; then
        reportRun python -c \
            "import open3d.ml.tf.ops; print('Tensorflow Ops library loaded:', open3d.ml.tf.ops)"
    fi
}

# Use: run_unit_tests
run_cpp_unit_tests() {
    unitTestFlags=
    [ "${LOW_MEM_USAGE-}" = "ON" ] && unitTestFlags="--gtest_filter=-*Reduce*Sum*"
    reportRun ./bin/tests "$unitTestFlags"
    echo
}

run_python_tests() {
    pytest_args=(../python/test/)
    if [ "$BUILD_PYTORCH_OPS" == "OFF" ] || [ "$BUILD_TENSORFLOW_OPS" == "OFF" ]; then
        echo Testing ML Ops disabled
        pytest_args+=(--ignore ../python/test/ml_ops/)
    fi
    reportRun python -m pytest "${pytest_args[@]}"
}

# test_cpp_example runExample
# Need variable OPEN3D_INSTALL_DIR
test_cpp_example() {

    cd ../docs/_static/C++
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=${OPEN3D_INSTALL_DIR} ..
    make -j"$NPROC" VERBOSE=1
    runExample="$1"
    if [ "$runExample" == ON ]; then
        ./TestVisualizer
    fi
    cd ../../../../build
}