# Foxglove Parameter Editor

An extension for Foxglove for conveniently adjusting paramameters of different types.

![panel](docs/images/foxglove-param-editor-panel.png)
![setup](docs/images/foxglove-param-editor.png)

## Installation

This plugin relies on the `/rosapi/nodes` service to be available on the robot in order to build a list of running nodes.
This can either be done by making sure [rosbridge_server](https://github.com/RobotWebTools/rosbridge_suite/blob/ros2/rosbridge_server/launch/rosbridge_websocket_launch.xml) is running:

```ros2 launch rosbridge_server rosbridge_websocket_launch.xml```

or solely the [rosapi node](https://github.com/RobotWebTools/rosbridge_suite/blob/ros2/rosapi/scripts/rosapi_node):

```ros2 run rosapi rosapi_node```

Use in a launch file:
```python
    rosbridge_launch = IncludeLaunchDescription(
        AnyLaunchDescriptionSource(
            os.path.join(
                get_package_share_directory("rosbridge_server"),
                "launch",
                "rosbridge_websocket_launch.xml",
            )
        ),
    )
```    

## Compile from source

`npm install` to install dependencies
`npm run local-install` to build and install for a local copy of the Foxglove Studio Desktop App
`npm run package` to package it up into a .foxe file

[Foxglove](https://foxglove.dev) allows developers to create [extensions](https://docs.foxglove.dev/docs/visualization/extensions/introduction), or custom code that is loaded and executed inside the Foxglove application. This can be used to add custom panels. Extensions are authored in TypeScript using the `@foxglove/extension` SDK.

## Develop

Extension development uses the `npm` package manager to install development dependencies and run build scripts.

To install extension dependencies, run `npm` from the root of the extension package.

```sh
npm install
```

To build and install the extension into your local Foxglove desktop app, run:

```sh
npm run local-install
```

Open the Foxglove desktop (or `ctrl-R` to refresh if it is already open). Your extension is installed and available within the app.

## Package

Extensions are packaged into `.foxe` files. These files contain the metadata (package.json) and the build code for the extension.

Before packaging, make sure to set `name`, `publisher`, `version`, and `description` fields in _package.json_. When ready to distribute the extension, run:

```sh
npm run package
```

This command will package the extension into a `.foxe` file in the local directory.

## Publish

You can publish the extension to the public registry or privately for your organization.

See documentation here: https://docs.foxglove.dev/docs/visualization/extensions/publish/#packaging-your-extension

# Other resources 

- https://docs.foxglove.dev/extension-api/type-aliases/ExtensionPanelRegistration