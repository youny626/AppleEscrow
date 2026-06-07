# Artifact Appendix

Paper title: **Enabling Personal Dataflow Sovereignty via Bolt-on Data Escrow**

Requested Badge(s):
  - [x] **Available**
  - [ ] **Functional**
  - [ ] **Reproduced**

## Description

This repository contains the escrow prototype described in the paper *Enabling Personal Dataflow Sovereignty via Bolt-on Data Escrow* and relevant code for evaluation (in the `Benchmark` folder). 

There are three separate escrow implementations in three folders, `Escrow`, `Escrow-vtab-no-pushdown`, `Escrow-preload-to-sqlite`, corresponding to Virtual Tables with Pushdown, Virtual Tables, and Materialized Tables relational engine implementation described in the paper. Compile the project with only one of the folders.

In the folder `EscrowApp`, the file `MyApp.swift` is the main entrypoint for testing the prototype. It initializes the escrow instance and calls the `run(access(), compute())` function.  There are some examples in the file that you can modify and test. 

### Security/Privacy Issues and Ethical Concerns

Testing this prototype requires you to grant access permissions to protected resources on your device, such as photo library, contacts, and location.

## Environment

To test the prototype, you need a Mac device (ex. MacBook) with Xcode installed, and open the project as an Xcode project. You need to make sure relevant capabilities (`entitlements`) and permissions (`info.plist`) are set in Xcode before you run the app.

### Accessibility

You may access the artifact using `git clone https://github.com/youny626/AppleEscrow.git`.

## Notes on Reusability

The concrete implementation of the escrow's programming interface (`run(access(), compute()`) is highly flexible; specifically, one can extend the Materialized Tables or Virtual Tables modules to incorporate other data types, or implement a new relational engine that executes `access()`. In addition, the delegated computation model of the escrow architecture can be adapted to other ecosystems beyond the Apple ecosystem we have experimented with.
