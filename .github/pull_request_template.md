## Description
<!--
Brief description of the changes in this PR. Give enough context for the reviewer to understand why the change is being made.
-->

Related GitHub Issue: <!--#issue_number or N/A-->

## Testing
<!--
Describe how a reviewer should test these changes.
-->

## Contributor Checklist

- [ ] File names follow naming conventions and folder structure
- [ ] Platform engineer documentation is in README.md
- [ ] Developer documentation is the top-level description property
- [ ] Example of defining the Resource Type is in the developer documentation
- [ ] Example of using the Resource Type with a Container is in the developer documentation
- [ ] Verified the output of `rad resource-type show` is correct
- [ ] All properties in the Resource Type definition have clear descriptions
- [ ] Enum properties have values defined in `enum: []`
- [ ] Required properties are listed in `required: []` for every object property (not just the top-level properties)
- [ ] Properties about the deployed resource, such as connection strings, are defined as read-only properties and are marked as `readOnly: true`
- [ ] Recipes include a results output variable with all read-only properties set
- [ ] Environment-specific parameters, such as a vnet ID, are exposed for platform engineers to set in the Environment
- [ ] Recipes use the [Recipe context object](https://docs.radapp.io/reference/context-schema/) when possible
- [ ] Recipes are provided for at least one platform
- [ ] Recipes handle secrets securely
- [ ] Recipes are idempotent
- [ ] Resource types and recipes were tested
