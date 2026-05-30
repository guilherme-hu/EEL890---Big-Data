-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


--  MODELO ENTIDADE-RELACIONAMENTO - SISTEMA DE LOCAÇÃO DE VEÍCULOS
-- Esse drop é importante, porque senão, se vc rodar mais de uma vez, dá erro de "vc já criou essa tabela"
DROP DATABASE IF EXISTS locadora;
CREATE DATABASE IF NOT EXISTS locadora CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE locadora;
 
CREATE TABLE Endereco (
    Id_endereco     INT             NOT NULL AUTO_INCREMENT,
    UF              CHAR(2)         NOT NULL,           
    Cidade          VARCHAR(100)    NOT NULL,
    CEP             CHAR(8)         NOT NULL,
    Bairro          VARCHAR(100)    NOT NULL,
    Rua_Avenida     VARCHAR(150)    NOT NULL,
    Numero          VARCHAR(20)     NULL,   
    Complemento     VARCHAR(100)    NULL,       -- pode ser nulo (bloco, apto, casa...)
 
    CONSTRAINT PK_Endereco PRIMARY KEY (Id_endereco),
    CONSTRAINT CHK_CEP_len  CHECK (CHAR_LENGTH(CEP) = 8)
);
 
--    Pix e boleto são processados na hora, só o cartão que entra no modelo
CREATE TABLE Dados_cobranca (
    Id_dados_cobranca   INT             NOT NULL AUTO_INCREMENT,
    Numero_cartao       VARCHAR(19)     NOT NULL,
    Validade            DATE            NOT NULL,
    Nome_titular        VARCHAR(150)    NOT NULL,
    CPF_titular         CHAR(11)        NOT NULL,
    CVV                 VARCHAR(4)      NOT NULL,   -- 3 dígitos ou 4 depende do cartão
 
    CONSTRAINT PK_Dados_cobranca    PRIMARY KEY (Id_dados_cobranca),
    CONSTRAINT UQ_cpf_titular   	UNIQUE (CPF_titular),
    CONSTRAINT CHK_Cartao_len       CHECK (CHAR_LENGTH(Numero_cartao) BETWEEN 13 AND 19),
    CONSTRAINT CHK_CPF_titular      CHECK (CHAR_LENGTH(CPF_titular) = 11),
    CONSTRAINT CHK_CVV              CHECK (CHAR_LENGTH(CVV) IN (3, 4))
);
 
CREATE TABLE Documento_cliente (
    Id_documento            INT         NOT NULL AUTO_INCREMENT,
    CPF                     CHAR(11) 	NULL, -- Pode ser nulo, caso PASS não seja nulo
    CNH                     CHAR(11) 	NULL, -- Pode ser nulo, caso HAB ESTR  não seja nulo
    Passaporte              VARCHAR(30) NULL,   -- formato variável por país 
    Habilitacao_estrangeira VARCHAR(30) NULL,   -- formato variável por país
 
    CONSTRAINT PK_Documento_cliente PRIMARY KEY (Id_documento),
    -- Pelo menos um documento de identidade deve estar presente
    CONSTRAINT CHK_Doc_identidade   CHECK (CPF IS NOT NULL OR Passaporte IS NOT NULL),
    -- Pelo menos uma habilitação deve estar presente
    CONSTRAINT CHK_Doc_habilitacao  CHECK (CNH IS NOT NULL OR Habilitacao_estrangeira IS NOT NULL),
    CONSTRAINT CHK_CPF_len          CHECK (CPF IS NULL OR CHAR_LENGTH(CPF) = 11),
    CONSTRAINT CHK_CNH_len          CHECK (CNH IS NULL OR CHAR_LENGTH(CNH) = 11)
);
 
CREATE TABLE Cliente (
    Id_cliente          INT             NOT NULL AUTO_INCREMENT,
    Id_documento        INT             NOT NULL,
    Id_endereco         INT             NOT NULL,
    Id_dados_cobranca   INT             NULL,   -- apenas obrigatório para pagamento por cartão
    Nome_completo       VARCHAR(200)    NOT NULL,
    Genero              VARCHAR(30)     NOT NULL,   
    Nacionalidade       VARCHAR(60)     NOT NULL,
    Data_nascimento     DATE            NOT NULL,
    Telefone            VARCHAR(20)     NOT NULL,   
    Email               VARCHAR(150)    NOT NULL,
 
    CONSTRAINT PK_Cliente           PRIMARY KEY (Id_cliente),
    CONSTRAINT FK_Cli_Documento     FOREIGN KEY (Id_documento)      REFERENCES Documento_cliente(Id_documento),
    CONSTRAINT FK_Cli_Endereco      FOREIGN KEY (Id_endereco)       REFERENCES Endereco(Id_endereco),
    CONSTRAINT FK_Cli_Cobranca      FOREIGN KEY (Id_dados_cobranca) REFERENCES Dados_cobranca(Id_dados_cobranca)
);
 
CREATE TABLE Grupo (
    Id_grupo        INT             NOT NULL AUTO_INCREMENT,
    Nome            VARCHAR(100)    NOT NULL,
    Descricao       VARCHAR(500)    NOT NULL,
    Diaria_grupo    DECIMAL(10,2)   NOT NULL,
 
    CONSTRAINT PK_Grupo PRIMARY KEY (Id_grupo)
);
 -- Dados Que não mudam na vida útil do veículo 
CREATE TABLE Especificacoes_const (
    Id_spec_const           INT     NOT NULL AUTO_INCREMENT,
    Vidro_eletrico          TINYINT(1) NOT NULL DEFAULT 0,  -- 0=Não / 1=Sim
    Trava_eletrica          TINYINT(1) NOT NULL DEFAULT 0,
    Dir_hidraulica          TINYINT(1) NOT NULL DEFAULT 0,
    Ar_condicionado         TINYINT(1) NOT NULL DEFAULT 0,
    Direcao_automatica      TINYINT(1) NOT NULL DEFAULT 0,  -- 0=Manual / 1=Automático
    Qtd_pessoas             INT     NOT NULL,
    Capacidade_mala         INT     NOT NULL,   -- em litros
    Pressao_pneu_ideal      INT     NOT NULL,   -- em PSI
    Capacidade_oleo         INT     NOT NULL,   -- em litros
    Capacidade_tanque       INT     NOT NULL,   -- em litros
 
    CONSTRAINT PK_Spec_const PRIMARY KEY (Id_spec_const)
);

-- especificações que podem mudar
CREATE TABLE Especificacoes_var (
    Id_spec_var     INT     NOT NULL AUTO_INCREMENT,
    Gasolina        INT     NOT NULL,   -- nível atual (litros) -> capacidade de tanque
    Oleo            INT     NOT NULL,   -- nível atual (litros) ->  capacidade de oleo
    Pressao_pneu    INT     NOT NULL,   -- em PSI
 
    CONSTRAINT PK_Spec_var 			PRIMARY KEY (Id_spec_var),
    CONSTRAINT CHK_Gasolina         CHECK (Gasolina >= 0),
    CONSTRAINT CHK_Oleo             CHECK (Oleo >= 0)
);
 
CREATE TABLE Veiculo (
    Id_veiculo      INT             NOT NULL AUTO_INCREMENT,
    Id_grupo        INT             NOT NULL,
    Id_spec_var     INT             NOT NULL,
    Id_spec_const   INT             NOT NULL,
    Categoria       VARCHAR(50)     NOT NULL,   -- Sedan, SUV, Hatch, Esportivo, etc
    Marca           VARCHAR(60)     NOT NULL,
    Modelo          VARCHAR(60)     NOT NULL,
    Ano             CHAR(4)         NOT NULL,
    Versao          VARCHAR(60)     NOT NULL,
    Cor             VARCHAR(40)     NOT NULL,
    Chassi          CHAR(17)    	NOT NULL,
    Placa           CHAR(7)      	NOT NULL,       -- tipo AAA-9999 ou AAA9A99
 
    CONSTRAINT PK_Veiculo           PRIMARY KEY (Id_veiculo),
    CONSTRAINT UQ_Chassi            UNIQUE      (Chassi),
    CONSTRAINT UQ_Placa             UNIQUE      (Placa),
    CONSTRAINT FK_Vei_Grupo         FOREIGN KEY (Id_grupo)      REFERENCES Grupo(Id_grupo),
    CONSTRAINT FK_Vei_SpecVar       FOREIGN KEY (Id_spec_var)   REFERENCES Especificacoes_var(Id_spec_var),
    CONSTRAINT FK_Vei_SpecConst     FOREIGN KEY (Id_spec_const) REFERENCES Especificacoes_const(Id_spec_const),
    CONSTRAINT CHK_Ano				CHECK(LENGTH(Ano = 4) AND Ano IS NOT NULL),
    CONSTRAINT CHK_Placa			CHECK(LENGTH(Placa)=7),
    CONSTRAINT CHK_Chassi      		CHECK (LENGTH(Chassi) = 17 AND UPPER(Chassi) NOT LIKE '%I%' AND UPPER(Chassi) NOT LIKE '%O%' AND UPPER(Chassi) NOT LIKE '%Q%')
);
  CREATE TABLE Imagem_veiculo (
    Id_imagem_veiculo   INT             NOT NULL AUTO_INCREMENT,
    Id_veiculo			INT 			NOT NULL,
    Url_arquivo         VARCHAR(500)    NOT NULL,
    Tipo_imagem         VARCHAR(50)     NOT NULL,   -- ex: 'frente', 'lateral', 'interior'
    Data_upload         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
 
    CONSTRAINT PK_Imagem_veiculo    PRIMARY KEY (Id_imagem_veiculo),
    CONSTRAINT UQ_url_arquivo		UNIQUE (Url_arquivo),
    CONSTRAINT FK_veiculo			FOREIGN KEY(Id_veiculo)	REFERENCES Veiculo(Id_veiculo)
);
CREATE TABLE Empresa (
    Id_empresa      INT             NOT NULL AUTO_INCREMENT,
    Id_endereco     INT             NOT NULL,
    Nome_empresa    VARCHAR(150)    NOT NULL,
    CNPJ            CHAR(14)        NOT NULL,

    CONSTRAINT PK_Empresa       PRIMARY KEY (Id_empresa),
    CONSTRAINT UQ_CNPJ          UNIQUE (CNPJ),
    CONSTRAINT FK_Emp_Endereco  FOREIGN KEY (Id_endereco) REFERENCES Endereco(Id_endereco),
    CONSTRAINT CHK_CNPJ_len     CHECK (CHAR_LENGTH(CNPJ) = 14)
);
 
CREATE TABLE Patio (
    Id_patio        INT             NOT NULL AUTO_INCREMENT,
    Id_endereco     INT             NOT NULL,
    Id_empresa      INT             NOT NULL,
    Nome_patio      VARCHAR(150)    NOT NULL,
 
    CONSTRAINT PK_Patio         PRIMARY KEY (Id_patio),
    CONSTRAINT FK_Pat_Endereco  FOREIGN KEY (Id_endereco) REFERENCES Endereco(Id_endereco),
    CONSTRAINT FK_Pat_Empresa   FOREIGN KEY (Id_empresa)  REFERENCES Empresa(Id_empresa)
);
 
CREATE TABLE Vaga (
    Id_vaga         INT     NOT NULL AUTO_INCREMENT,
    Id_patio        INT     NOT NULL,
    Id_veiculo      INT     NULL,   -- NULL quando a vaga está livre
	Alfanum_vaga    VARCHAR(20)     NOT NULL,
    CONSTRAINT PK_Vaga        PRIMARY KEY (Id_vaga),
    CONSTRAINT FK_Vag_Patio     FOREIGN KEY (Id_patio)   REFERENCES Patio(Id_patio),
    CONSTRAINT FK_Vag_Veiculo   FOREIGN KEY (Id_veiculo) REFERENCES Veiculo(Id_veiculo)
);
 

CREATE TABLE Seguro (
    Id_seguro       INT             NOT NULL AUTO_INCREMENT,
    Nivel           VARCHAR(50)     NOT NULL,   -- ex: Básico, Intermediário, Total
    Descricao       VARCHAR(500)    NOT NULL,
    Diaria_seguro   DECIMAL(10,2)   NOT NULL,
 
    CONSTRAINT PK_Seguro PRIMARY KEY (Id_seguro)
);
 

CREATE TABLE Pagamento (
    Id_pagamento    INT     NOT NULL AUTO_INCREMENT,
    Nota_fiscal     CHAR(44)     NOT NULL, -- 44 dígitos no código da nota fiscal
 
    CONSTRAINT PK_Pagamento PRIMARY KEY (Id_pagamento)
);
 
--     Pátio_origem e Pátio_fim referenciam a mesma tabela Patio
CREATE TABLE Reserva (
    Id_reserva              INT             NOT NULL AUTO_INCREMENT,
    Id_cliente              INT             NOT NULL,
    Id_grupo                INT             NOT NULL,
    Id_pagamento            INT             NOT NULL,
    Id_seguro               INT             NOT NULL,
    Id_patio_origem         INT             NOT NULL,
    Id_patio_fim            INT             NOT NULL,
    Preco_final             DECIMAL(10,2)   NOT NULL,
    Data_inicio_combinada   DATETIME        NOT NULL,
    Data_fim_combinada      DATETIME        NOT NULL,
    Estado_reserva          TINYINT         NOT NULL DEFAULT 0,
        -- 0 = em andamento | 1 = cancelada | 2 = confirmada
    Data_reserva            DATE            NOT NULL DEFAULT (CURRENT_DATE),
 
    CONSTRAINT PK_Reserva               PRIMARY KEY (Id_reserva),
    CONSTRAINT FK_Res_Cliente           FOREIGN KEY (Id_cliente)        REFERENCES Cliente(Id_cliente),
    CONSTRAINT FK_Res_Grupo             FOREIGN KEY (Id_grupo)          REFERENCES Grupo(Id_grupo),
    CONSTRAINT FK_Res_Pagamento         FOREIGN KEY (Id_pagamento)      REFERENCES Pagamento(Id_pagamento),
    CONSTRAINT FK_Res_Seguro        	FOREIGN KEY (Id_seguro)       REFERENCES Seguro(Id_seguro),
    CONSTRAINT FK_Res_PatioOrigem       FOREIGN KEY (Id_patio_origem)   REFERENCES Patio(Id_patio),
    CONSTRAINT FK_Res_PatioFim          FOREIGN KEY (Id_patio_fim)      REFERENCES Patio(Id_patio),
    CONSTRAINT CHK_Data_fim             CHECK (Data_fim_combinada >= Data_inicio_combinada)
    
);
 

CREATE TABLE Caucao(
Id_caucao	INT 				NOT NULL AUTO_INCREMENT,
Valor		DECIMAL(10,2)		NOT NULL,
Estado_caucao   TINYINT         NOT NULL DEFAULT 0, -- 0=Bloqueado | 1=Liberado | 2=Cobrança parcial | 3=Cobrança total
CONSTRAINT PK_Caucao PRIMARY KEY (Id_caucao)
);
 -- Confirma se o cliente pegou o carro
CREATE TABLE Locacao (
    Id_locacao      INT         NOT NULL AUTO_INCREMENT,
    Id_reserva      INT         NOT NULL,
    Id_veiculo      INT         NOT NULL,
    Id_spec_var     INT         NOT NULL,   -- foto/analise do estado do veículo na retirada
    Id_caucao       INT         NOT NULL,
    Id_patio		INT 		NOT NULL, 
    Data_locacao    DATETIME    NOT NULL,   -- data/hora real da retirada
 
    CONSTRAINT PK_Locacao           PRIMARY KEY (Id_locacao),
    CONSTRAINT FK_Loc_Reserva       FOREIGN KEY (Id_reserva)  REFERENCES Reserva(Id_reserva),
    CONSTRAINT FK_Loc_Veiculo       FOREIGN KEY (Id_veiculo)  REFERENCES Veiculo(Id_veiculo),
    CONSTRAINT FK_Loc_SpecVar       FOREIGN KEY (Id_spec_var) REFERENCES Especificacoes_var(Id_spec_var),
	CONSTRAINT FK_Patio           	FOREIGN KEY (Id_patio)	  REFERENCES Patio(Id_patio), 
    CONSTRAINT FK_Loc_Caucao    FOREIGN KEY (Id_caucao)   REFERENCES Caucao(Id_caucao)
);
 
CREATE TABLE Custos_devolucao (
    Id_custos_devolucao     INT             NOT NULL AUTO_INCREMENT,
    Id_caucao               INT             NOT NULL,
    Id_pagamento            INT             NOT NULL,
    Valor_atraso            DECIMAL(10,2)   NULL,   -- atraso na devolução
    Valor_reparos           DECIMAL(10,2)   NULL,   -- danos ao veículo
    Valor_estado_veiculo    DECIMAL(10,2)   NULL,   -- tanque vazio, carro sujo, etc.

    CONSTRAINT PK_Custos_dev    PRIMARY KEY (Id_custos_devolucao),
    CONSTRAINT FK_CusDev_Caucao FOREIGN KEY (Id_caucao)     REFERENCES Caucao(Id_caucao),
    CONSTRAINT FK_CusDev_Pag    FOREIGN KEY (Id_pagamento)  REFERENCES Pagamento(Id_pagamento)
);
CREATE TABLE Devolucao (
    Id_devolucao  		  	INT         NOT NULL AUTO_INCREMENT,
    Id_spec_var				INT         NOT NULL,
    Id_custos_devolucao     INT         NOT NULL,
    Id_locacao    		 	 INT         NOT NULL,
    Id_vaga         		INT         NOT NULL,
    Data_devolucao 			 DATETIME    NOT NULL,
	
    CONSTRAINT PK_Devolucao         PRIMARY KEY (Id_devolucao),
    CONSTRAINT FK_spec_var			FOREIGN KEY (Id_spec_var) REFERENCES Especificacoes_var(Id_spec_var),
	CONSTRAINT FK_Dev_Custos        FOREIGN KEY (Id_custos_devolucao) REFERENCES Custos_devolucao(Id_custos_devolucao),
    CONSTRAINT FK_Dev_Locacao       FOREIGN KEY (Id_locacao) REFERENCES Locacao(Id_locacao),
    CONSTRAINT FK_Dev_Vaga          FOREIGN KEY (Id_vaga)    REFERENCES Vaga(Id_vaga)
);


CREATE TABLE Extensao_reserva (
    Id_extensao_reserva INT             NOT NULL AUTO_INCREMENT,
    Id_locacao          INT             NOT NULL,
    Id_reserva          INT             NOT NULL,
    Id_pagamento        INT             NOT NULL,
    Qtd_dias            INT             NOT NULL,
    Valor               DECIMAL(10,2)   NOT NULL,
    Data_extensao       DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT PK_Extensao      PRIMARY KEY (Id_extensao_reserva),
    CONSTRAINT FK_Ext_Locacao   FOREIGN KEY (Id_locacao)    REFERENCES Locacao(Id_locacao),
    CONSTRAINT FK_Ext_Reserva   FOREIGN KEY (Id_reserva)    REFERENCES Reserva(Id_reserva),
    CONSTRAINT FK_Ext_Pagamento FOREIGN KEY (Id_pagamento)  REFERENCES Pagamento(Id_pagamento),
    CONSTRAINT CHK_Qtd_dias     CHECK (Qtd_dias > 0)
);

CREATE TABLE Imagem_devolucao(
	Id_imagem_devolucao		INT 			NOT NULL AUTO_INCREMENT,
    Id_devolucao			INT				NOT NULL,
    Url_arquivo				VARCHAR(255)	NOT NULL,
    Tipo_imagem				VARCHAR(255)	NOT NULL,
    Data_upload				DATETIME		NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT	PK_imagem_devolucao	PRIMARY KEY (Id_imagem_devolucao),
    CONSTRAINT	FK_devolucao		FOREIGN KEY (Id_devolucao)	REFERENCES Devolucao(Id_devolucao),
	CONSTRAINT	UQ_url_arquivo				UNIQUE (Url_arquivo)
);
