#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

echo "Converting butane to ignition template..."
butane -s flatcar.bu.yaml -o flatcar.ign.tmpl

echo "Done: flatcar.ign.tmpl"