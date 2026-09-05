##===----------------------------------------------------------------------===##
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##===----------------------------------------------------------------------===##

# Detects number and memory amounts of local GPUs.
# Outputs relevant bazelrc lines.
#
# The Windows counterpart of detect_local_resources.sh. Only the nvidia-smi
# branch is here. amd-smi and rocm-smi are Linux only, so an AMD card on Windows
# reports no GPUs, which is the same answer the shell script gives for a machine
# it cannot measure and is better than reporting a number that is wrong. There
# is no macOS branch for the obvious reason.

$ErrorActionPreference = "Stop"

if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
  # No GPUs
  Write-Output "build --local_resources=gpu-memory=0"
  exit 0
}

# One line per GPU, in MiB.
$output = @(nvidia-smi --query-gpu=memory.total --format=noheader,nounits |
  Where-Object { $_.Trim() -ne "" })

# nvidia-smi is on the path on any machine with the driver installed, including
# one with no NVIDIA card in it, where it exits nonzero and prints nothing. The
# shell script never meets that case because on Linux the tool arrives with the
# driver and the driver arrives with the card.
if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
  Write-Output "build --local_resources=gpu-memory=0"
  exit 0
}

# We assume all GPUs are the same, so just grab the first
$memMib = [int]$output[0].Trim()
# We specify GiB for local memory
$memGib = [int][Math]::Floor($memMib / 1024)

$gpuCount = $output.Count

Write-Output "build --local_resources=gpu-memory=$memGib"
# At this point, we assume we have at least 1 GPU
Write-Output "build --local_resources=gpu-1=1"
if ($gpuCount -ge 2) {
  Write-Output "build --local_resources=gpu-2=1"
}
if ($gpuCount -ge 4) {
  Write-Output "build --local_resources=gpu-4=1"
}
if ($gpuCount -ge 8) {
  Write-Output "build --local_resources=gpu-8=1"
}
