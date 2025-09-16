$childrenList = @()

$children = @(
     @{
          name  = 'yahoo.com'
          value = '2'
     },
     @{
          name  = 'stupid.com'
          value = '2'
     },
     @{
          name  = 'is.com'
          value = '2'
     },
     @{
          name = 'asStupidDoes.com'
          value = '2'
     },
     @{
          name = 'NoneAsStupidAsMe.com'
          value = '2'
     }
)


foreach ($child in $children) {
     $childrenList += @{
          "settingValueTemplateReference" = $null
          children                        = @(
               @{
                    '@odata.type'                      = "#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance"
                    "settingDefinitionId"              = "device_vendor_msft_policy_config_internetexplorer_allowsitetozoneassignmentlist_iz_zonemapprompt_key"
                    "settingInstanceTemplateReference" = $null
                    "simpleSettingValue"               = @{
                         '@odata.type'                   = "#microsoft.graph.deviceManagementConfigurationStringSettingValue"
                         "settingValueTemplateReference" = $null
                         "value"                         = $child.name
                    }
               },
               @{'@odata.type'                         = "#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance"
                    "settingDefinitionId"              = "device_vendor_msft_policy_config_internetexplorer_allowsitetozoneassignmentlist_iz_zonemapprompt_value"
                    "settingInstanceTemplateReference" = $null
                    "simpleSettingValue"               = @{
                         '@odata.type'                   = "#microsoft.graph.deviceManagementConfigurationStringSettingValue"
                         "settingValueTemplateReference" = $null
                         "value"                         = $child.value
                    }
               }
          )
     } 
}

$policy = '{
     "creationSource": null,
     "description": "",
     "name": "WebDomainsTrustedSites",
     "platforms": "windows10",
     "priorityMetaData": null,
     "roleScopeTagIds": [],
     "settingCount": 1,
     "technologies": "mdm",
     "templateReference": {
          "templateId": "",
          "templateFamily": "none",
          "templateDisplayName": null,
          "templateDisplayVersion": null
     },
     "settings": [
          {
               "id": "0",
               "settingInstance": {
                    "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                    "settingDefinitionId": "device_vendor_msft_policy_config_internetexplorer_allowsitetozoneassignmentlist",
                    "settingInstanceTemplateReference": null,
                    "choiceSettingValue": {
                         "settingValueTemplateReference": null,
                         "value": "device_vendor_msft_policy_config_internetexplorer_allowsitetozoneassignmentlist_1",
                         "children": [
                              {
                                   "@odata.type": "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance",
                                   "settingDefinitionId": "device_vendor_msft_policy_config_internetexplorer_allowsitetozoneassignmentlist_iz_zonemapprompt",
                                   "settingInstanceTemplateReference": null,
                                   "groupSettingCollectionValue": []
                              }
                         ]
                    }
               }
          }
     ]
}' | ConvertFrom-Json -Depth 100

$policy.settings[0].settingInstance.choiceSettingValue.children[0].groupSettingCollectionValue = $childrenList 

$GraphSplat = @{
     method      = 'POST'
     uri         = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
     body        = $policy | ConvertTo-Json -Depth 100
     contentType = 'application/json'
}

Invoke-MgGraphRequest @GraphSplat