#!/bin/bash
#
# Script para verificar a sincronização do fork 'nfe-fincatto-fork' com o
# repositório original 'fincatto/nfe' e automatizar a atualização de versão:
#
# 1. Detecta a última versão publicada pela Fincatto (tags do upstream).
# 2. Se houver versão nova, pergunta se deseja atualizar. Ao confirmar:
#    - Cria a branch nfe_XXXX (ex: 5.0.64 -> nfe_5064) a partir da branch atual.
#    - Faz o merge da tag da nova versão.
#    - Resolve automaticamente os conflitos conhecidos:
#        * arquivos de teste removidos no fork -> mantém removidos;
#        * pom.xml -> aceita o do upstream e reaplica os patches locais
#          (java.version e xmlsec, configuráveis abaixo).
#    - Oferece o push da branch (substitui o botão 'Sync Fork' do GitHub).
#    - Oferece preparar o projeto consumidor (PROJETO_DIR): cria a mesma
#      branch nfe_XXXX e atualiza a propriedade <nfe.version> no pom.xml.
# 3. Verifica java/xmlsec no pom.xml e o status de sincronização das branches.
#
# Passos que continuam manuais: compilar os dois projetos na IDE e testar as NF-es.
#

set -e

# --- Configurações ---
UPSTREAM_REPO_URL="https://github.com/fincatto/nfe.git"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"

# Patches locais que são reaplicados no pom.xml após o merge de uma nova versão
LOCAL_JAVA_VERSION="1.8"
LOCAL_XMLSEC_VERSION="3.0.6"

# Projeto consumidor da biblioteca (recebe branch nova e atualização do <nfe.version>)
PROJETO_DIR="/Users/ericgravescamollez/Dev/Projects/NetBeansProjects/ipack-git"
PROJETO_NFE_PROPERTY="nfe.version"

# --- Cores para o output ---
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# --- Funções auxiliares ---
check_latest_nfe_version() {
    echo -e "${COLOR_BLUE}Verificando a última versão da biblioteca NF-e (fincatto/nfe)...${COLOR_RESET}"

    # Versão local declarada no pom.xml (primeira ocorrência de <version> = versão do projeto)
    LOCAL_VERSION=$(grep -m1 '<version>' pom.xml | sed -E 's/.*<version>(.*)<\/version>.*/\1/')

    # Última tag publicada no repositório original (ex: v5.0.63)
    LATEST_TAG=$(git ls-remote --tags --sort=-v:refname ${UPSTREAM_REPO_URL} 'v*' 2>/dev/null \
        | grep -v '\^{}' | head -n1 | sed -E 's/.*refs\/tags\/v?//')

    if [[ -z "$LATEST_TAG" ]]; then
        echo -e "  - ${COLOR_RED}Não foi possível consultar as tags do repositório original (sem conexão?).${COLOR_RESET}"
        echo ""
        return
    fi

    # Remove sufixo -SNAPSHOT para comparação
    LOCAL_VERSION_CLEAN="${LOCAL_VERSION%-SNAPSHOT}"

    echo -e "  - Versão local (pom.xml): ${LOCAL_VERSION}"
    echo -e "  - Última versão publicada (fincatto/nfe): ${LATEST_TAG}"

    if [[ "$LOCAL_VERSION_CLEAN" == "$LATEST_TAG" ]]; then
        echo -e "  - ${COLOR_GREEN}🎉 Você está na última versão da NF-e.${COLOR_RESET}"
    else
        NEWEST=$(printf '%s\n%s\n' "$LOCAL_VERSION_CLEAN" "$LATEST_TAG" | sort -V | tail -n1)
        if [[ "$NEWEST" == "$LATEST_TAG" ]]; then
            echo -e "  - ${COLOR_YELLOW}⚠️ Existe uma versão mais recente disponível: ${LATEST_TAG} (local: ${LOCAL_VERSION}).${COLOR_RESET}"
            ask_to_update
        else
            echo -e "  - ${COLOR_GREEN}Sua versão local (${LOCAL_VERSION}) é mais recente que a última tag publicada (${LATEST_TAG}).${COLOR_RESET}"
        fi
    fi
    echo ""
}

resolve_merge_conflicts() {
    echo -e "  - ${COLOR_YELLOW}O merge encontrou conflitos. Tentando resolver automaticamente os conflitos conhecidos...${COLOR_RESET}"

    # 1. Arquivos removidos no fork mas modificados no upstream: mantém removidos
    git status --porcelain | awk '$1 == "DU"' | cut -c4- | while IFS= read -r FILE; do
        echo "    - Mantendo removido: ${FILE}"
        git rm --quiet -- "$FILE"
    done

    # 2. pom.xml: usa a versão do upstream e reaplica os patches locais
    if git status --porcelain | grep -q '^UU pom.xml'; then
        echo "    - pom.xml: usando a versão nova do upstream e reaplicando patches locais (java ${LOCAL_JAVA_VERSION}, xmlsec ${LOCAL_XMLSEC_VERSION})..."
        git checkout --theirs -- pom.xml
        sed -i '' -E "s|<java.version>[^<]*</java.version>|<java.version>${LOCAL_JAVA_VERSION}</java.version>|" pom.xml
        sed -i '' -E "/<artifactId>xmlsec<\/artifactId>/{n;s|<version>[^<]*</version>|<version>${LOCAL_XMLSEC_VERSION}</version>|;}" pom.xml
        git add pom.xml
    fi

    # Se ainda restar algum conflito desconhecido, não arrisca: deixa para resolução manual
    if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
        return 1
    fi
    git commit --no-edit --quiet
    return 0
}

update_consumer_project() {
    if [[ ! -d "${PROJETO_DIR}/.git" ]]; then
        return
    fi
    PROJETO_NOME=$(basename "${PROJETO_DIR}")

    echo ""
    read -r -p "  Deseja preparar também o projeto '${PROJETO_NOME}' (criar branch '${NEW_BRANCH}' e atualizar <${PROJETO_NFE_PROPERTY}> para ${LATEST_TAG})? (s/N) " RESPOSTA_PROJETO
    if [[ ! "$RESPOSTA_PROJETO" =~ ^[SsYy]$ ]]; then
        echo -e "  - ${COLOR_YELLOW}Projeto '${PROJETO_NOME}' não alterado. Lembre-se de criar a branch e atualizar o pom.xml manualmente.${COLOR_RESET}"
        return
    fi

    if git -C "${PROJETO_DIR}" show-ref --verify --quiet "refs/heads/${NEW_BRANCH}"; then
        echo -e "  - ${COLOR_YELLOW}A branch '${NEW_BRANCH}' já existe em '${PROJETO_NOME}'. Mudando para ela...${COLOR_RESET}"
        git -C "${PROJETO_DIR}" checkout --quiet "${NEW_BRANCH}"
    else
        echo "  - Criando a branch '${NEW_BRANCH}' em '${PROJETO_NOME}' (a partir de $(git -C "${PROJETO_DIR}" rev-parse --abbrev-ref HEAD))..."
        git -C "${PROJETO_DIR}" checkout --quiet -b "${NEW_BRANCH}"
    fi

    sed -i '' -E "s|<${PROJETO_NFE_PROPERTY}>[^<]*</${PROJETO_NFE_PROPERTY}>|<${PROJETO_NFE_PROPERTY}>${LATEST_TAG}</${PROJETO_NFE_PROPERTY}>|" "${PROJETO_DIR}/pom.xml"
    NOVA_PROP=$(grep -o "<${PROJETO_NFE_PROPERTY}>[^<]*</${PROJETO_NFE_PROPERTY}>" "${PROJETO_DIR}/pom.xml")
    echo -e "  - ${COLOR_GREEN}pom.xml de '${PROJETO_NOME}' atualizado: ${NOVA_PROP}${COLOR_RESET}"
    echo "    (Alteração NÃO commitada — revise na IDE antes de commitar.)"
}

show_final_reminder() {
    echo ""
    echo -e "${COLOR_BLUE}--- Próximos passos (manuais) ---${COLOR_RESET}"
    echo "  1. Compile o projeto NF-e (fork) na IDE."
    echo "  2. Compile o seu projeto ($(basename "${PROJETO_DIR}"))."
    echo "  3. Teste a emissão das NF-es antes de fazer commit/push definitivo."
}

show_available_changes() {
    # Lista os commits do upstream entre a versão local e a nova (requer as tags,
    # baixadas no fetch inicial). Oculta os commits automáticos do maven-release-plugin.
    if ! git rev-parse -q --verify "v${LOCAL_VERSION_CLEAN}" > /dev/null 2>&1 || \
       ! git rev-parse -q --verify "v${LATEST_TAG}" > /dev/null 2>&1; then
        return
    fi
    echo ""
    echo -e "${COLOR_BLUE}  --- Alterações disponíveis (v${LOCAL_VERSION_CLEAN} -> v${LATEST_TAG}) ---${COLOR_RESET}"
    git log --oneline --no-decorate --no-merges "v${LOCAL_VERSION_CLEAN}..v${LATEST_TAG}" \
        | grep -vE '\[maven-release-plugin\]' \
        | sed 's/^/    /'
    TOTAL_COMMITS=$(git rev-list --count "v${LOCAL_VERSION_CLEAN}..v${LATEST_TAG}")
    echo -e "    ${COLOR_YELLOW}(${TOTAL_COMMITS} commits no total; commits automáticos de release ocultados)${COLOR_RESET}"
}

ask_to_update() {
    show_available_changes

    # Se não estiver rodando em um terminal interativo, apenas informa e não pergunta
    if [[ ! -t 0 ]]; then
        echo "    Recomendação: Execute o script em um terminal para poder atualizar interativamente."
        return
    fi

    # Nome da nova branch derivado da versão: 5.0.63 -> nfe_5063
    NEW_BRANCH="nfe_$(echo "$LATEST_TAG" | tr -d '.')"

    echo ""
    read -r -p "  Deseja criar a branch '${NEW_BRANCH}' e atualizá-la para a versão ${LATEST_TAG} agora? (s/N) " RESPOSTA
    if [[ "$RESPOSTA" =~ ^[SsYy]$ ]]; then
        echo ""
        echo -e "${COLOR_BLUE}Atualizando para a versão ${LATEST_TAG}...${COLOR_RESET}"
        git fetch --quiet ${UPSTREAM_REMOTE} --tags

        if git show-ref --verify --quiet "refs/heads/${NEW_BRANCH}"; then
            echo -e "  - ${COLOR_YELLOW}A branch '${NEW_BRANCH}' já existe. Mudando para ela...${COLOR_RESET}"
            git checkout "${NEW_BRANCH}"
        else
            echo -e "  - Criando a branch '${NEW_BRANCH}' a partir da branch atual ($(git rev-parse --abbrev-ref HEAD))..."
            git checkout -b "${NEW_BRANCH}"
        fi

        MERGE_OK=0
        if git merge --no-edit --quiet "v${LATEST_TAG}" > /dev/null 2>&1; then
            MERGE_OK=1
        elif resolve_merge_conflicts; then
            MERGE_OK=1
        fi

        if [[ "$MERGE_OK" -eq 1 ]]; then
            echo -e "  - ${COLOR_GREEN}🎉 Branch '${NEW_BRANCH}' atualizada com sucesso para a versão ${LATEST_TAG}.${COLOR_RESET}"

            # Push da nova branch (substitui o 'Sync Fork' da página do GitHub)
            echo ""
            read -r -p "  Deseja enviar a branch '${NEW_BRANCH}' para o seu fork no GitHub agora (git push)? (s/N) " RESPOSTA_PUSH
            if [[ "$RESPOSTA_PUSH" =~ ^[SsYy]$ ]]; then
                git push -u origin "${NEW_BRANCH}"
                echo -e "  - ${COLOR_GREEN}Branch '${NEW_BRANCH}' enviada para o GitHub.${COLOR_RESET}"
            else
                echo -e "  - ${COLOR_YELLOW}Push adiado. Envie depois com: git push -u origin ${NEW_BRANCH}${COLOR_RESET}"
            fi

            # Prepara o projeto consumidor (branch + <nfe.version> no pom.xml)
            update_consumer_project
            show_final_reminder
        else
            echo -e "  - ${COLOR_RED}⚠️ O merge encontrou conflitos que o script não sabe resolver sozinho.${COLOR_RESET}"
            echo "    Arquivos ainda em conflito:"
            git diff --name-only --diff-filter=U | sed 's/^/      - /'
            echo "    Resolva os conflitos manualmente e finalize com 'git commit',"
            echo "    ou desfaça a tentativa com 'git merge --abort'."
        fi
    else
        echo -e "  - ${COLOR_YELLOW}Atualização adiada. Você pode atualizar depois criando a branch:${COLOR_RESET}"
        echo "    git checkout -b ${NEW_BRANCH} && git merge v${LATEST_TAG}"
    fi
}

check_java_config() {
    echo -e "${COLOR_BLUE}Verificando configuração Java e xmlsec no pom.xml...${COLOR_RESET}"
    POM_FILE="pom.xml"
    JAVA_VERSION=$(grep -E '<java.version>.*</java.version>' "$POM_FILE" | sed -E 's/.*<java.version>(.*)<\/java.version>.*/\1/')
    XMLSEC_VERSION=$(grep -A1 '<artifactId>xmlsec</artifactId>' "$POM_FILE" | grep '<version>' | sed -E 's/.*<version>(.*)<\/version>.*/\1/')

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
git fetch --tags ${UPSTREAM_REMOTE}
echo "Busca concluída."
echo ""

# --- 3. Verificação da última versão da NF-e ---
check_latest_nfe_version

# --- 4. Verificação do pom.xml ---
check_java_config

# --- 5. Comparações de Sincronização ---
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo -e "${COLOR_BLUE}--- Status do seu Fork no GitHub (origin/${CURRENT_BRANCH}) vs. Fincatto Original (upstream/${UPSTREAM_BRANCH}) ---${COLOR_RESET}"
# Se a branch atual ainda não existe no GitHub (recém-criada), avisa e encerra
if ! git show-ref --verify --quiet "refs/remotes/origin/${CURRENT_BRANCH}"; then
    echo -e "${COLOR_YELLOW}⚠️ A branch '${CURRENT_BRANCH}' ainda não existe no seu fork do GitHub.${COLOR_RESET}"
    echo "   Recomendação: Envie-a com 'git push -u origin ${CURRENT_BRANCH}' e rode este script novamente."
    echo ""
    echo -e "${COLOR_BLUE}===================================================================${COLOR_RESET}"
    echo "Verificação de Sincronização Concluída."
    echo -e "${COLOR_BLUE}===================================================================${COLOR_RESET}"
    exit 0
fi

# Compara sua branch de trabalho remota (no seu fork do GitHub) com a master do upstream
COMMITS_BEHIND_UPSTREAM=$(git rev-list --right-only --count origin/${CURRENT_BRANCH}...${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH})
COMMITS_AHEAD_UPSTREAM=$(git rev-list --left-only --count origin/${CURRENT_BRANCH}...${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH})

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
COMMITS_BEHIND_ORIGIN=$(git rev-list --right-only --count ${CURRENT_BRANCH}...origin/${CURRENT_BRANCH})
COMMITS_AHEAD_ORIGIN=$(git rev-list --left-only --count ${CURRENT_BRANCH}...origin/${CURRENT_BRANCH})

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
