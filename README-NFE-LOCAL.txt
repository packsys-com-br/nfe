Guia para usar a versão local da biblioteca nfe-fincatto-fork no projeto ipack-git

Este guia descreve os passos necessários para garantir que o projeto 'ipack-git' utilize a sua versão local e customizada da biblioteca 'nfe-fincatto-fork' (especificamente a branch 'nfe_5040'), em vez de uma versão do repositório central do Maven.

Problema Comum:
O erro 'java.lang.UnsupportedClassVersionError' geralmente ocorre quando uma dependência (como a 'nfe') foi compilada com uma versão mais recente do Java (ex: Java 11) do que o ambiente de execução do seu projeto (ex: Java 8).

Solução:
Para resolver isso, você precisa garantir que a versão da biblioteca 'nfe' que o 'ipack-git' utiliza seja compilada localmente com a mesma versão do Java do seu ambiente (Java 8).

Passos:

1.  **Garantir que o projeto 'nfe-fincatto-fork' está atualizado e compilado localmente:**
    a.  Navegue até o diretório raiz do seu projeto 'nfe-fincatto-fork':
        `cd ~/Dev/Projects/NetBeansProjects/nfe-fincatto-fork`

    b.  Certifique-se de estar na branch correta (ex: 'nfe_5040'):
        `git checkout nfe_5040`

    c.  Compile e instale o projeto 'nfe-fincatto-fork' no seu repositório Maven local. Isso fará com que o Maven use a sua versão customizada.
        `mvn clean install -DskipTests`
        (O parâmetro `-DskipTests` é opcional e serve para agilizar a compilação, pulando a execução dos testes)

2.  **Compilar os módulos do projeto 'ipack-git' (na ordem correta):**
    a.  Navegue de volta para o diretório raiz do seu projeto 'ipack-git':
        `cd ~/Dev/Projects/NetBeansProjects/ipack-git`

    b.  Compile e instale o módulo 'NfeCore':
        `mvn clean install -DskipTests`

    c.  Compile e instale o módulo 'IPACK Web':
        `mvn clean install -DskipTests`

Observação:
Se, por algum motivo, você precisar 'esquecer' a versão local da 'nfe' e forçar o Maven a baixar do repositório central (o que pode reintroduzir o problema de compatibilidade de Java se a versão central for para Java 11), você pode limpar o artefato do seu repositório local Maven:
`rm -rf ~/.m2/repository/com/github/wmixvideo/nfe/5.0.40`
No entanto, para manter a compatibilidade com Java 8, é recomendado seguir os passos acima após qualquer alteração significativa no projeto 'nfe-fincatto-fork'.