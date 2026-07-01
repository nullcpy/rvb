#!/bin/bash
set -euo pipefail

sudo apt-get install -y -q libbcprov-java
BCPROV=$(find /usr/share/java -name "bcprov-*.jar" | grep -v debian | head -1)
sudo cp "$BCPROV" "$JAVA_HOME/lib/bcprov.jar"
LAST_PROV=$(grep "^security.provider\." "$JAVA_HOME/conf/security/java.security" | grep -oP '(?<=security\.provider\.)\d+' | sort -n | tail -1)
echo "security.provider.$((LAST_PROV+1))=org.bouncycastle.jce.provider.BouncyCastleProvider" | sudo tee -a "$JAVA_HOME/conf/security/java.security"
