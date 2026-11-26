#!/bin/bash
#
# Script para verificar a sincronização do fork 'nfe-fincatto-fork' com o
# repositório original 'fincatto/nfe' e automatizar a atualização de versão:
#
# 1. Detecta a última versão publicada pela Fincatto (tags do upstream).
#    - Lista os commits entre a versão local e a última versão publicada
#      (é exatamente o que entra no merge; commits automáticos de release
#      do maven-release-plugin são ocultados).
#    - Lista também, apenas para informação, os commits que já estão no
#      upstream/master mas ainda NÃO saíram em nenhuma versão publicada
#      (por isso o GitHub pode mostrar PRs mais novos que a última tag).
#      Esses commits não entram no merge; virão na próxima versão.
#      O script recomenda aguardar a versão publicada e mostra como
#      antecipá-los com 'git cherry-pick' em caso de prazo legal, explicando
#      por que não é o ideal (commit duplicado -> conflitos no próximo merge,
#      código ainda sem release oficial, versão do pom.xml que não
#      corresponde ao código real).
#    - Mostra a quantidade e a lista de Pull Requests abertos no repositório
#      original (API pública do GitHub via curl + jq, sem login). São propostas
#      ainda em análise: não estão nem no master e podem mudar ou ser recusadas.
#      Sem conexão ou com limite da API atingido, apenas avisa e segue.
# 2. Se houver versão nova, pergunta se deseja atualizar. Ao confirmar:
#    - Cria a branch nfe_XXXX (ex: 5.0.64 -> nfe_5064) a partir da branch atual.
#    - Faz o merge da tag da nova versão.
#    - Resolve automaticamente os conflitos conhecidos:
#        * arquivos de teste removidos no fork -> mantém removidos;
#        * pom.xml -> aceita o do upstream e reaplica os patches locais
#          (java.version e xmlsec, configuráveis abaixo).
#    - Oferece o push da branch (substitui o botão 'Sync Fork' do GitHub).
#    - Oferece preparar os projetos consumidores da biblioteca, configurados
#      na lista PROJETOS_DIRS (hoje: ipack-git e bwWeb_aws-git):
#        * exibe um menu numerado com os projetos e a branch atual de cada um
#          (0 ou Enter vazio = nenhum / encerrar);
#        * no projeto escolhido, cria (ou muda para) a mesma branch nfe_XXXX,
#          a partir da branch atual DAQUELE projeto, e atualiza a propriedade
#          <nfe.version> no pom.xml (sem commit);
#        * em seguida pergunta "Deseja aplicar para outro projeto? (s/N)";
#          com 's' o menu volta, marcando os já preparados com ✔;
#        * ao final, avisa quais projetos ficaram sem preparar.
# 3. Verifica java/xmlsec no pom.xml e o status de sincronização das branches.
#
# Antes de rodar: deixe cada projeto consumidor na branch base correta, pois a
# branch nfe_XXXX nasce da branch atual de cada repositório (fork incluído).
# Para incluir outro projeto consumidor, adicione o caminho em PROJETOS_DIRS.
#
# Passos que continuam manuais: compilar o fork e os projetos consumidores na
# IDE, testar a emissão das NF-es e fazer commit/push nos projetos consumidores.
#
# Uso: ./aplicar_patches_git_nfe.sh   (em terminal interativo, na raiz do fork)
#

set -e

# --- Configurações ---
UPSTREAM_REPO_URL="https://github.com/fincatto/nfe.git"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"

# Patches locais que são reaplicados no pom.xml após o merge de uma nova versão
LOCAL_JAVA_VERSION="1.8"
LOCAL_XMLSEC_VERSION="3.0.6"

# Projetos consumidores da biblioteca (recebem branch nova e atualização do <nfe.version>).
# Para incluir outro projeto, basta adicionar o caminho nesta lista.
PROJETOS_DIRS=(
    "/Users/ericgravescamollez/Dev/Projects/NetBeansProjects/ipack-git"
    "/Users/ericgravescamollez/Dev/Projects/NetBeansProjects/bwWeb_aws-git"
)
PROJETO_NFE_PROPERTY="nfe.version"

# Preenchido durante a execução com os projetos efetivamente preparados
PROJETOS_PREPARADOS=()

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
        show_unreleased_changes
        show_open_pull_requests
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

# Prepara UM projeto consumidor: cria/muda para a branch nfe_XXXX e atualiza o <nfe.version>.
# Retorna 1 (sem abortar o script) se algo impedir a preparação.
prepare_consumer_project() {
    local DIR="$1"
    local NOME
    NOME=$(basename "${DIR}")

    if [[ ! -d "${DIR}/.git" ]]; then
        echo -e "  - ${COLOR_RED}'${DIR}' não é um repositório git. Projeto ignorado.${COLOR_RESET}"
        return 1
    fi
    if [[ ! -f "${DIR}/pom.xml" ]] || ! grep -q "<${PROJETO_NFE_PROPERTY}>" "${DIR}/pom.xml"; then
        echo -e "  - ${COLOR_RED}pom.xml de '${NOME}' não possui a propriedade <${PROJETO_NFE_PROPERTY}>. Projeto ignorado.${COLOR_RESET}"
        return 1
    fi

    echo ""
    echo -e "${COLOR_BLUE}  Preparando '${NOME}'...${COLOR_RESET}"
    if git -C "${DIR}" show-ref --verify --quiet "refs/heads/${NEW_BRANCH}"; then
        echo -e "  - ${COLOR_YELLOW}A branch '${NEW_BRANCH}' já existe em '${NOME}'. Mudando para ela...${COLOR_RESET}"
        if ! git -C "${DIR}" checkout --quiet "${NEW_BRANCH}"; then
            echo -e "  - ${COLOR_RED}Não foi possível mudar para a branch '${NEW_BRANCH}' em '${NOME}' (alterações pendentes?).${COLOR_RESET}"
            return 1
        fi
    else
        echo "  - Criando a branch '${NEW_BRANCH}' em '${NOME}' (a partir de $(git -C "${DIR}" rev-parse --abbrev-ref HEAD))..."
        if ! git -C "${DIR}" checkout --quiet -b "${NEW_BRANCH}"; then
            echo -e "  - ${COLOR_RED}Não foi possível criar a branch '${NEW_BRANCH}' em '${NOME}'.${COLOR_RESET}"
            return 1
        fi
    fi

    LC_ALL=C sed -i '' -E "s|<${PROJETO_NFE_PROPERTY}>[^<]*</${PROJETO_NFE_PROPERTY}>|<${PROJETO_NFE_PROPERTY}>${LATEST_TAG}</${PROJETO_NFE_PROPERTY}>|" "${DIR}/pom.xml"
    NOVA_PROP=$(grep -o "<${PROJETO_NFE_PROPERTY}>[^<]*</${PROJETO_NFE_PROPERTY}>" "${DIR}/pom.xml" | sort -u | tr '\n' ' ')
    echo -e "  - ${COLOR_GREEN}pom.xml de '${NOME}' atualizado: ${NOVA_PROP}${COLOR_RESET}"
    echo "    (Alteração NÃO commitada — revise na IDE antes de commitar.)"
    PROJETOS_PREPARADOS+=("${NOME}")
    return 0
}

# Menu: escolhe o projeto consumidor a preparar e, ao final de cada um,
# pergunta se deseja aplicar em outro projeto.
update_consumer_projects() {
    local TOTAL=${#PROJETOS_DIRS[@]}
    local FEITO=()
    local I ESCOLHA RESPOSTA_OUTRO RESTANTES DIR NOME MARCA

    [[ "$TOTAL" -eq 0 ]] && return

    while true; do
        echo ""
        echo -e "${COLOR_BLUE}  --- Projetos consumidores (branch '${NEW_BRANCH}', <${PROJETO_NFE_PROPERTY}> ${LATEST_TAG}) ---${COLOR_RESET}"
        for ((I = 0; I < TOTAL; I++)); do
            DIR="${PROJETOS_DIRS[$I]}"
            NOME=$(basename "${DIR}")
            if [[ "${FEITO[$I]}" == "1" ]]; then
                MARCA="${COLOR_GREEN}✔ já preparado${COLOR_RESET}"
            elif [[ -d "${DIR}/.git" ]]; then
                MARCA="(branch atual: $(git -C "${DIR}" rev-parse --abbrev-ref HEAD))"
            else
                MARCA="${COLOR_RED}(repositório não encontrado)${COLOR_RESET}"
            fi
            echo -e "    $((I + 1))) ${NOME}  ${MARCA}"
        done
        echo "    0) Nenhum / encerrar"
        read -r -p "  Qual projeto deseja preparar? " ESCOLHA

        if [[ "$ESCOLHA" == "0" || -z "$ESCOLHA" ]]; then
            break
        fi
        if [[ ! "$ESCOLHA" =~ ^[0-9]+$ ]] || (( ESCOLHA < 1 || ESCOLHA > TOTAL )); then
            echo -e "  - ${COLOR_RED}Opção inválida: '${ESCOLHA}'.${COLOR_RESET}"
            continue
        fi
        I=$((ESCOLHA - 1))
        if [[ "${FEITO[$I]}" == "1" ]]; then
            echo -e "  - ${COLOR_YELLOW}'$(basename "${PROJETOS_DIRS[$I]}")' já foi preparado nesta execução.${COLOR_RESET}"
            continue
        fi

        if prepare_consumer_project "${PROJETOS_DIRS[$I]}"; then
            FEITO[$I]=1
        fi

        # Conta quantos projetos ainda não foram preparados
        RESTANTES=0
        for ((I = 0; I < TOTAL; I++)); do
            [[ "${FEITO[$I]}" == "1" ]] || RESTANTES=$((RESTANTES + 1))
        done
        if [[ "$RESTANTES" -eq 0 ]]; then
            echo -e "  - ${COLOR_GREEN}Todos os projetos consumidores foram preparados.${COLOR_RESET}"
            break
        fi

        echo ""
        read -r -p "  Deseja aplicar para outro projeto? (s/N) " RESPOSTA_OUTRO
        if [[ ! "$RESPOSTA_OUTRO" =~ ^[SsYy]$ ]]; then
            break
        fi
    done

    # Lembra dos projetos que ficaram sem preparar
    for ((I = 0; I < TOTAL; I++)); do
        if [[ "${FEITO[$I]}" != "1" ]]; then
            echo -e "  - ${COLOR_YELLOW}Projeto '$(basename "${PROJETOS_DIRS[$I]}")' não alterado. Lembre-se de criar a branch '${NEW_BRANCH}' e atualizar o pom.xml manualmente.${COLOR_RESET}"
        fi
    done
}

show_final_reminder() {
    local LISTA
    if [[ ${#PROJETOS_PREPARADOS[@]} -gt 0 ]]; then
        LISTA=$(printf '%s, ' "${PROJETOS_PREPARADOS[@]}")
        LISTA="${LISTA%, }"
    else
        LISTA="nenhum projeto consumidor foi preparado"
    fi
    echo ""
    echo -e "${COLOR_BLUE}--- Próximos passos (manuais) ---${COLOR_RESET}"
    echo "  1. Compile o projeto NF-e (fork) na IDE."
    echo "  2. Compile o(s) projeto(s) consumidor(es): ${LISTA}."
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
    show_unreleased_changes
    show_open_pull_requests
}

show_unreleased_changes() {
    # Lista (apenas para informação) os commits que já estão no master do upstream
    # mas ainda não saíram em nenhuma release (posteriores à última tag).
    # Eles NÃO entram no merge — só virão quando a Fincatto publicar a próxima versão.
    local REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
    if ! git rev-parse -q --verify "v${LATEST_TAG}" > /dev/null 2>&1 || \
       ! git rev-parse -q --verify "${REF}" > /dev/null 2>&1; then
        return
    fi
    local PENDENTES
    PENDENTES=$(git log --oneline --no-decorate --no-merges "v${LATEST_TAG}..${REF}" | grep -vE '\[maven-release-plugin\]' || true)
    if [[ -z "$PENDENTES" ]]; then
        return
    fi
    echo ""
    echo -e "${COLOR_BLUE}  --- Já no ${REF}, ainda sem release (posteriores à v${LATEST_TAG}) ---${COLOR_RESET}"
    echo "$PENDENTES" | sed 's/^/    /'
    echo -e "    ${COLOR_YELLOW}(Não entram no merge; virão na próxima versão publicada pela Fincatto.)${COLOR_RESET}"

    # Orientação sobre antecipar esses commits via cherry-pick
    local EXEMPLO_HASH
    EXEMPLO_HASH=$(echo "$PENDENTES" | head -n1 | awk '{print $1}')
    echo ""
    echo -e "    ${COLOR_YELLOW}Recomendação: aguarde a próxima versão publicada antes de trazer esses commits.${COLOR_RESET}"
    echo "    Se precisar de algum deles antes (ex.: prazo legal de uma Nota Técnica), é possível"
    echo "    aplicá-lo na branch nova com cherry-pick:"
    echo "        git cherry-pick ${EXEMPLO_HASH}"
    echo "    Por que não é o ideal:"
    echo "      - O commit fica duplicado (hash diferente do upstream); quando a próxima versão"
    echo "        sair, o merge da tag pode gerar conflitos nesses mesmos arquivos."
    echo "      - O código ainda não passou pelo processo de release da Fincatto e pode ser"
    echo "        ajustado/corrigido antes da publicação."
    echo "      - A versão no pom.xml continuaria ${LATEST_TAG}, mas com código diferente da"
    echo "        ${LATEST_TAG} oficial, dificultando saber o que está realmente em produção."
}

show_open_pull_requests() {
    # Lista os Pull Requests abertos no repositório original (API pública do GitHub,
    # sem autenticação). São propostas ainda em análise: não estão nem no master.
    if ! command -v curl > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
        echo -e "    ${COLOR_YELLOW}(curl/jq não encontrados — não foi possível listar os Pull Requests abertos.)${COLOR_RESET}"
        return
    fi
    local REPO_PATH API_JSON TOTAL_PRS
    REPO_PATH=$(echo "${UPSTREAM_REPO_URL}" | sed -E 's|^https://github.com/||; s|\.git$||')

    # -L: o repositório pode ter sido transferido (ex.: fincatto/nfe -> wmixvideo/nfe)
    API_JSON=$(curl -sfL --max-time 15 -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO_PATH}/pulls?state=open&per_page=100") || API_JSON=""
    if [[ -z "$API_JSON" ]] || ! TOTAL_PRS=$(echo "$API_JSON" | jq 'if type == "array" then length else error end' 2>/dev/null); then
        echo ""
        echo -e "    ${COLOR_YELLOW}(Não foi possível consultar os Pull Requests abertos no GitHub — sem conexão ou limite da API atingido.)${COLOR_RESET}"
        return
    fi

    echo ""
    if [[ "$TOTAL_PRS" -eq 0 ]]; then
        echo -e "${COLOR_BLUE}  --- Pull Requests abertos em ${REPO_PATH}: nenhum ---${COLOR_RESET}"
        return
    fi
    # Nome atual do repositório (após eventual transferência), ex.: wmixvideo/nfe
    REPO_PATH=$(echo "$API_JSON" | jq -r '.[0].base.repo.full_name // empty')
    [[ -z "$REPO_PATH" ]] && REPO_PATH=$(echo "${UPSTREAM_REPO_URL}" | sed -E 's|^https://github.com/||; s|\.git$||')
    [[ "$TOTAL_PRS" -ge 100 ]] && TOTAL_PRS="100+"
    echo -e "${COLOR_BLUE}  --- Pull Requests abertos em ${REPO_PATH}: ${TOTAL_PRS} ---${COLOR_RESET}"
    echo "$API_JSON" | jq -r '.[] | "    #\(.number) \(.title)  (\(.user.login), \(.created_at[:10]))"'
    echo -e "    ${COLOR_YELLOW}(Ainda em análise pela Fincatto: não estão no master e podem ser alterados ou recusados.)${COLOR_RESET}"
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

            # Prepara os projetos consumidores (menu: branch + <nfe.version> no pom.xml)
            update_consumer_projects
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
