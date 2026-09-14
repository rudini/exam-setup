FROM codercom/code-server:latest

USER root

# Install Node.js 22 LTS via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install global npm packages
RUN npm install -g typescript ts-node @angular/cli

# Workspace-Template mit vorinstallierten Dependencies
COPY workspace-template/ /opt/workspace-template/
RUN cd /opt/workspace-template && npm install && chmod -R 755 /opt/workspace-template

# Disable extensions marketplace:
# 1. Remove extensionsGallery from product.json
RUN python3 -c "import json; path='/usr/lib/code-server/lib/vscode/product.json'; d=json.load(open(path)); d.pop('extensionsGallery', None); json.dump(d, open(path,'w'))"
# 2. Replace hardcoded open-vsx.org URLs in server-main.js with an unreachable address
RUN sed -i \
    's|https://open-vsx\.org/vscode/gallery|http://localhost:1/disabled|g; s|https://open-vsx\.org/vscode/item|http://localhost:1/disabled|g; s|https://open-vsx\.org|http://localhost:1|g' \
    /usr/lib/code-server/lib/vscode/out/server-main.js

# Machine-level settings (cannot be overridden by user):
# - Hide Extensions icon from activity bar
# - Disable auto-update and auto-check
RUN mkdir -p /home/coder/.local/share/code-server/Machine \
    && cat > /home/coder/.local/share/code-server/Machine/settings.json <<'EOF'
{
    "extensions.autoUpdate": false,
    "extensions.autoCheckUpdates": false,
    "workbench.activityBar.additionalContentEnabled": false,
    "workbench.extensions.disableRecommendations": true,
    "extensions.ignoreRecommendations": true,
    "chat.disableAIFeatures": true,
    "chat.commandCenter.enabled": false,
    "chat.agent.enabled": false,
    "inlineChat.enabled": false
}
EOF
    # Hide the Extensions viewlet from the activity bar via workbench state
RUN mkdir -p /home/coder/.local/share/code-server/User \
    && cat > /home/coder/.local/share/code-server/User/settings.json <<'EOF'
{
    "extensions.autoUpdate": false,
    "extensions.autoCheckUpdates": false,
    "workbench.extensions.disableRecommendations": true,
    "extensions.ignoreRecommendations": true,
    "chat.disableAIFeatures": true,
    "chat.commandCenter.enabled": false,
    "chat.agent.enabled": false,
    "inlineChat.enabled": false
}
EOF
RUN chown -R coder:coder /home/coder/.local

USER coder

ENV DISABLE_TELEMETRY=true \
    SERVICE_URL="http://localhost:1/disabled" \
    ITEM_URL="http://localhost:1/disabled" \
    CS_DISABLE_GETTING_STARTED_OVERRIDE=1

EXPOSE 8080
