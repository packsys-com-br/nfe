#!/bin/bash
#
# Script para verificar o status de sincronização do seu fork 'nfe-fincatto-fork'
# com o repositório original 'fincatto/nfe' no GitHub, respeitando o fluxo de trabalho:
# 1. Sincronização via botão 'Sync' no GitHub.
# 2. Pull das alterações para a branch local de trabalho (a branch atual).
#

set -e

# --- Configurações ---
UPSTREAM_REPO_URL="https://github.com/fincatto/nfe.git"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"

# --- Cores para o output ---
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# --- Funções auxiliares ---
check_java_config() {
    echo -e "${COLOR_BLUE}Verificando configuração Java e xmlsec no pom.xml...${COLOR_RESET}"
    POM_FILE="pom.xml"
    JAVA_VERSION=$(grep -E '<java.version>.*</java.version>' "$POM_FILE" | sed -E 's/.*<java.version>(.*)<\/java.version>.*/\1/')
    XMLSEC_VERSION=$(grep -E '<artifactId>xmlsec<\/artifactId>\s*<version>.*<\/version>' "$POM_FILE" | sed -E 's/.*<version>(.*)<\/version>.*/\1/')

    if [[ "$JAVA_VERSION" == "1.8" && "$XMLSEC_VERSION" == "3.0.6" ]]; then
        echo -e "  - ${COLOR_GREEN}pom.xml: java.version=${JAVA_VERSION}, xmlsec.version=${XMLSEC_VERSION} (OK - Compatível com Java 8 e configurações atuais).${COLOR_RESET}"
    elif [[ "$JAVA_VERSION" == "1.8" && "$XMLSEC_VERSION" == "2.3.4" ]]; then
        echo -e "  - ${COLOR_YELLOW}pom.xml: java.version=${JAVA_VERSION}, xmlsec.version=${XMLSEC_VERSION} (OK - Compatível com Java 8, versão segura do xmlsec).${COLOR_RESET}"
    else
        echo -e "  - ${COLOR_RED}pom.xml: java.version=${JAVA_VERSION}, xmlsec.version=${XMLSEC_VERSION} (ATENÇÃO: As versões podem não ser compatíveis com Java 8).${COLOR_RESET}"
    fi
    echo ""
}

# --- Início do Script ---
echo -e "${COLOR_BLUE}===================================================================${COLOR_RESET}"
echo -e "${COLOR_BLUE} Verificador de Sincronização do Fork Fincatto NFe ${COLOR_RESET}"
echo -e "${COLOR_BLUE}===================================================================${COLOR_RESET}"
echo ""

# --- 1. Verifica e configura o remote 'upstream' ---
if ! git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
    echo -e "${COLOR_YELLOW}Configurando o repositório original (upstream) pela primeira vez...${COLOR_RESET}"
    git remote add ${UPSTREAM_REMOTE} ${UPSTREAM_REPO_URL}
    echo -e "${COLOR_GREEN}Repositório '${UPSTREAM_REMOTE}' adicionado com sucesso.${COLOR_RESET}"
    echo ""
fi

# --- 2. Busca as atualizações de todos os remotes ---
echo "Buscando as atualizações mais recentes do seu fork (origin) e do original (upstream)..."
git fetch origin
git fetch ${UPSTREAM_REMOTE}
echo "Busca concluída."
echo ""

# --- 3. Verificação do pom.xml ---
check_java_config

# --- 4. Comparações de Sincronização ---
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo -e "${COLOR_BLUE}--- Status do seu Fork no GitHub (origin/${CURRENT_BRANCH}) vs. Fincatto Original (upstream/${UPSTREAM_BRANCH}) ---${COLOR_RESET}"
# Compara sua branch de trabalho remota (no seu fork do GitHub) com a master do upstream
COMMITS_BEHIND_UPSTREAM=$(git rev-list --left-only --count origin/${CURRENT_BRANCH}...${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH})
COMMITS_AHEAD_UPSTREAM=$(git rev-list --right-only --count origin/${CURRENT_BRANCH}...${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH})

if [ "$COMMITS_BEHIND_UPSTREAM" -gt 0 ]; then
    echo -e "${COLOR_YELLOW}⚠️ Seu fork no GitHub (origin/${CURRENT_BRANCH}) está ${COMMITS_BEHIND_UPSTREAM} commit(s) ATRÁS do repositório original da Fincatto (upstream/${UPSTREAM_BRANCH}).${COLOR_RESET}"
    echo "   Recomendação: Vá para a página do seu fork no GitHub e use o botão 'Sync fork' para atualizar."
elif [ "$COMMITS_AHEAD_UPSTREAM" -gt 0 ]; then
    echo -e "${COLOR_GREEN}👍 Seu fork no GitHub (origin/${CURRENT_BRANCH}) tem ${COMMITS_AHEAD_UPSTREAM} commit(s) que não estão no original (OK).${COLOR_RESET}"
else
    echo -e "${COLOR_GREEN}🎉 Seu fork no GitHub (origin/${CURRENT_BRANCH}) está sincronizado com o repositório original.${COLOR_RESET}"
fi
echo ""

echo -e "${COLOR_BLUE}--- Status da sua Branch Local (${CURRENT_BRANCH}) vs. seu Fork no GitHub (origin/${CURRENT_BRANCH}) ---${COLOR_RESET}"
# Compara sua branch de trabalho local com a branch de trabalho remota no seu fork
COMMITS_BEHIND_ORIGIN=$(git rev-list --left-only --count ${CURRENT_BRANCH}...origin/${CURRENT_BRANCH})
COMMITS_AHEAD_ORIGIN=$(git rev-list --right-only --count ${CURRENT_BRANCH}...origin/${CURRENT_BRANCH})

if [ "$COMMITS_BEHIND_ORIGIN" -gt 0 ]; then
    echo -e "${COLOR_YELLOW}⚠️ Sua branch local '${CURRENT_BRANCH}' está ${COMMITS_BEHIND_ORIGIN} commit(s) ATRÁS da sua branch remota (origin/${CURRENT_BRANCH}).${COLOR_RESET}"
    echo "   Recomendação: Execute 'git pull origin ${CURRENT_BRANCH}' (ou use o GitHub Desktop) para buscar as últimas alterações."
elif [ "$COMMITS_AHEAD_ORIGIN" -gt 0 ]; then
    echo -e "${COLOR_YELLOW}⬆️ Sua branch local '${CURRENT_BRANCH}' tem ${COMMITS_AHEAD_ORIGIN} commit(s) que ainda não foram enviados para o seu fork no GitHub.${COLOR_RESET}"
    echo "   Recomendação: Execute 'git push origin ${CURRENT_BRANCH}' (ou use o GitHub Desktop) para enviar suas alterações."
else
    echo -e "${COLOR_GREEN}🎉 Sua branch local '${CURRENT_BRANCH}' está sincronizada com seu fork no GitHub.${COLOR_RESET}"
fi
echo ""

echo -e "${COLOR_BLUE}===================================================================${COLOR_RESET}"
echo "Verificação de Sincronização Concluída."
echo -e "${COLOR_BLUE}===================================================================${COLOR_RESET}"
