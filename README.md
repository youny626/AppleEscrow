This repo contains the escrow prototype (and evaluation) implementation described in the paper *Enabling Personal Dataflow Sovereignty via Bolt-on Data Escrow*

To test the prototype, open the project in Xcode. There are three separate escrow implementations in three folders, `Escrow`, `Escrow-vtab-no-pushdown`, `Escrow-preload-to-sqlite`, corresponding to Virtual Tables with Pushdown, Virtual Tables, and Materialized Tables relational engine implementation described in the paper. Compile the project with only one of the folders.

In the folder `EscrowApp`, the file `MyApp.swift` is the main entrypoint. It initializes the escrow instance and calls the `run` function.  
There are some examples you can modify and test. You need to make sure relevant capabilities and permissions are set in Xcode before you run the app.
