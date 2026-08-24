Helix-Protocol/
├── README.md
├── helix_protocol_spec.md
├── package.json                 # pnpm/npm workspaces root (optional but nice)
├── pnpm-workspace.yaml          # or npm workspaces
│
├── contracts/                   # Foundry = Solidity source of truth
│   ├── foundry.toml
│   ├── src/
│   ├── test/
│   │   ├── unit/
│   │   ├── fuzz/
│   │   └── invariant/
│   ├── script/                  # forge deploy / init
│   ├── lib/
│   └── out/                     # gitignored; ABIs emitted here
│
├── apps/
│   ├── api/                     # Phase 4 REST (Nest/Express)
│   └── web/                     # frontend (later)
│
├── services/
│   ├── indexer/                 # Node indexer → Postgres/Redis
│   ├── keeper/                  # liquidation keeper
│   └── subgraph/                # optional Graph package
│
├── packages/
│   └── sdk/                     # shared TS types, ABI wrappers, addresses
│
└── .github/workflows/           # forge test + api/web CI