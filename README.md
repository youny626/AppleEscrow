# Artifact Appendix

Paper title: **Enabling Personal Dataflow Sovereignty via Bolt-on Data Escrow**

Requested Badge(s):
  - [x] **Available**
  - [ ] **Functional**
  - [ ] **Reproduced**

## Description

This repository contains the escrow prototype described in the paper *Enabling Personal Dataflow Sovereignty via Bolt-on Data Escrow* (PETS 2026). 

**BibTeX Citation:**
```bibtex
@article{zhu2026enabling,
  title={Enabling Personal Dataflow Sovereignty via Bolt-on Data Escrow},
  author={Zhu, Zhiru and Fernandez, Raul Castro},
  journal={Proceedings on Privacy Enhancing Technologies},
  year={2026}
}
```

There are three separate escrow implementations in three folders, `Escrow`, `Escrow-vtab-no-pushdown`, `Escrow-preload-to-sqlite`, corresponding to Virtual Tables with Pushdown, Virtual Tables, and Materialized Tables relational engine implementation described in the paper. Compile the project with only one of the folders.

In the folder `EscrowApp`, the file `MyApp.swift` is the main entrypoint for testing the prototype. It initializes the escrow instance and calls the `run(access(), compute())` function.  There are some examples in the file that you can modify and test. 

The code, results, and plotting scripts used for evaluation in the paper are in the `Benchmark` folder. 

### Security/Privacy Issues and Ethical Concerns

Testing this prototype requires you to grant access permissions to protected resources on your device, such as the photos library, contacts, and location. These permissions allow the escrow to invoke Apple's native data access SDKs to populate the underlying materialized tables or dynamically fetch data for virtual tables, then execute the `access()` function. The raw data never leaves the escrow. The output of the `access()` function is passed into the subsequent `compute()` function in `run()`, and only the output of `compute()` is returned to the app. 

## Environment

To test the prototype, you need a Mac device (ex. MacBook) with Xcode installed, and open the project as an Xcode project. You need to make sure relevant capabilities (`entitlements`) and permissions (`info.plist`) are set in Xcode before you run the app.

### Accessibility

You may access the artifact using <https://github.com/youny626/AppleEscrow/tree/main>.

## Notes on Reusability

The concrete implementation of the escrow's programming interface (`run(access(), compute()`) is highly flexible; specifically, one can extend the Materialized Tables or Virtual Tables modules to incorporate other data types, or implement a new relational engine that executes `access()`. In addition, the delegated computation model of the escrow architecture can be adapted to other ecosystems beyond the Apple ecosystem we have experimented with.
