#!/bin/bash
set -e

# Optimized SEA build script for PICO-8 Language Server on macOS
# This script focuses on creating a single executable application (SEA)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}PICO-8 Language Server - Optimized SEA Build Script${NC}"
echo "This script will create a standalone executable using Node.js SEA"

# Ensure we're in the project root 
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Make sure the build directory exists
mkdir -p build

# Step 1: Install necessary dependencies
echo -e "\n${YELLOW}Step 1: Installing dependencies...${NC}"
npm install
npm install --save vscode-languageserver
cd server && npm install --save vscode-languageserver && cd ..

# Install correct postject version for stability
npm install -g postject@1.0.0-alpha.5

# Step 2: Check if imports are already fixed
echo -e "\n${YELLOW}Step 2: Checking import paths...${NC}"
echo "Imports in server.ts are already updated to use 'vscode-languageserver'."
echo "Proceeding with build process."

# Step 3: Build the server with esbuild (full bundle)
echo -e "\n${YELLOW}Step 3: Building with esbuild...${NC}"
# Create a custom entry point that includes the --stdio parameter
ENTRY_POINT="build/entry.js"
mkdir -p $(dirname "$ENTRY_POINT")

cat > "$ENTRY_POINT" << 'EOF'
// This is a custom entry point that enforces stdio mode
// It must be added before the main server code
process.argv.push('--stdio');

// Import the server directly - import paths are already fixed
require('../server/src/server');
EOF

# No need for module-alias since imports are already fixed

# Bundle everything together with esbuild
mkdir -p ./server/out-min
npx esbuild "$ENTRY_POINT" \
  --bundle \
  --outfile=./server/out-min/main.js \
  --format=cjs \
  --platform=node \
  --minify

echo -e "${GREEN}✅ Server bundled successfully.${NC}"

# Step 4: Create SEA config pointing to the bundled output
echo -e "\n${YELLOW}Step 4: Updating SEA configuration...${NC}"
cat > sea-config.json << 'EOF'
{
  "main": "server/out-min/main.js",
  "output": "build/sea-prep.blob",
  "useCodeCache": true,
  "disableExperimentalSEAWarning": true
}
EOF

# Step 5: Generate the SEA preparation blob
echo -e "\n${YELLOW}Step 5: Generating SEA preparation blob...${NC}"
node --experimental-sea-config sea-config.json

if [ ! -f build/sea-prep.blob ]; then
  echo -e "${RED}Error: Failed to generate build/sea-prep.blob!${NC}"
  exit 1
fi

echo -e "${GREEN}✅ SEA preparation blob generated successfully.${NC}"

# Step 6: Use Node.js 22 from NVM
echo -e "\n${YELLOW}Step 6: Using Node.js 22 from NVM...${NC}"
# Try to load NVM if it's available
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  . "$HOME/.nvm/nvm.sh"
elif [ -s "/usr/local/opt/nvm/nvm.sh" ]; then
  . "/usr/local/opt/nvm/nvm.sh"
fi

# Switch to Node.js 22
if command -v nvm &> /dev/null; then
  echo "Switching to Node.js 22..."
  nvm use 22 || nvm install 22
else
  echo "NVM not found! Trying to proceed with system Node.js..."
fi

# Use current NVM Node.js
NODE_PATH=$(which node)
echo "Using Node.js from NVM: $NODE_PATH"

# Step 7: Prepare output paths
OUTPUT_PATH="$PROJECT_ROOT/build/pico8-ls"
TEMP_NODE="$PROJECT_ROOT/build/temp_node"

if [ -f "$OUTPUT_PATH" ]; then
  echo "Removing existing executable..."
  rm "$OUTPUT_PATH"
fi

echo "Copying $NODE_PATH to $TEMP_NODE"
cp "$NODE_PATH" "$TEMP_NODE"

# Step 8: Determine Node.js version and strategy
NODE_VERSION=$(node --version)
echo "Node.js version: $NODE_VERSION"

# Verify we're using NVM Node.js
if [[ "$NODE_PATH" != *".nvm"* ]]; then
  echo -e "${YELLOW}Warning: Not using Node.js from NVM. This might cause issues.${NC}"
  echo "You can set a specific Node.js version with: nvm use <version>"
fi

# Extract precise version information for sentinel detection
NODE_MAJOR=$(echo $NODE_VERSION | cut -d. -f1 | tr -d 'v')
NODE_MINOR=$(echo $NODE_VERSION | cut -d. -f2)

echo -e "\n${YELLOW}Step 8: Removing code signature from copy...${NC}"
codesign --remove-signature "$TEMP_NODE" || true

# Step 9: Determine the correct sentinel string based on Node.js version
echo -e "\n${YELLOW}Step 9: Determining correct sentinel...${NC}"
SENTINEL="NODE_SEA_FUSE"

# Inspect the binary to find the actual sentinel
echo "Searching for sentinel in binary..."
POTENTIAL_SENTINELS=$(strings "$TEMP_NODE" | grep -o "NODE_SEA_FUSE[_a-f0-9]*" || echo "")

if [ -n "$POTENTIAL_SENTINELS" ]; then
  # Use the first matching sentinel
  SENTINEL=$(echo "$POTENTIAL_SENTINELS" | head -1)
  echo "Found sentinel in binary: $SENTINEL"
else
  echo "No sentinel found, using default: $SENTINEL"
  # Node 20+ uses a specific hash-based sentinel string
  if [ "$NODE_MAJOR" -ge 20 ]; then
    echo "Warning: Using Node.js 20+ but couldn't find hash-based sentinel."
    echo "This might cause injection to fail."
  fi
fi

# Step 10: Inject the SEA blob
echo -e "\n${YELLOW}Step 10: Injecting SEA blob...${NC}"
echo "Using sentinel: $SENTINEL"

# Try alternative injection methods if needed
if [ "$NODE_MAJOR" -ge 20 ] && [ -x "$(command -v postject)" ]; then
  echo "Using advanced injection for Node.js 20+"
  postject "$TEMP_NODE" NODE_SEA_BLOB build/sea-prep.blob \
    --sentinel-fuse "$SENTINEL" \
    --macho-segment-name NODE_SEA
else
  echo "Using standard injection method"
  postject "$TEMP_NODE" NODE_SEA_BLOB build/sea-prep.blob \
    --sentinel-fuse "$SENTINEL" \
    --macho-segment-name NODE_SEA
fi

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✅ Blob injection successful!${NC}"
  mv "$TEMP_NODE" "$OUTPUT_PATH"
  
  # Step 11: Code sign the binary
  echo -e "\n${YELLOW}Step 11: Code signing the executable...${NC}"
  codesign --sign - "$OUTPUT_PATH" || true
  
  # Make it executable
  chmod +x "$OUTPUT_PATH"
  
  # Verify the executable was created successfully
  if [ -f "$OUTPUT_PATH" ] && [ -x "$OUTPUT_PATH" ]; then
    echo -e "\n${GREEN}✅ Build Successful!${NC}"
    echo -e "SEA executable created at: ${BLUE}$OUTPUT_PATH${NC}"
    echo -e "\nYou can run it with: ${BLUE}$OUTPUT_PATH${NC}"
  else
    echo -e "\n${RED}❌ Build failed: Executable not found or not executable${NC}"
    exit 1
  fi
else
  echo -e "${RED}Failed to inject blob with postject.${NC}"
  echo "Detailed error information:"
  # Try with different postject options for debugging
  echo "Trying with different postject options for debugging..."
  postject "$TEMP_NODE" NODE_SEA_BLOB build/sea-prep.blob \
    --sentinel-fuse "$SENTINEL" \
    --macho-segment-name NODE_SEA --debug
    
  echo -e "\n${YELLOW}Checking available sentinels in binary:${NC}"
  strings "$TEMP_NODE" | grep -i "NODE_SEA" || echo "No NODE_SEA strings found"
  
  echo -e "\n${RED}SEA build failed with Node.js 22.${NC}"
  echo -e "Tips for troubleshooting:"
  echo -e "1. Make sure your Node.js 22 is properly installed: nvm ls"
  echo -e "2. Try with a specific minor version: nvm use 22.1.0"
  echo -e "3. Check NVM setup: nvm which 22"
  exit 1
fi

# Clean up temporary files
rm -f "$ENTRY_POINT" sea-config.json build/sea-prep.blob
echo -e "\n${GREEN}Build process complete.${NC}"