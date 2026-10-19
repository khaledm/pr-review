# Which prompt reviews which file. Routes are checked top to bottom and the FIRST match wins,
# so the specific ones (Playwright tests, SSIS) come before the general ones (all C#).
#   Include / Exclude : globs on the repo-relative path (** = any folders, case-insensitive)
#   ContentRegex      : optional - the route only matches if the file's new content matches
#   Prompt            : file name in prompts\ (without .md)
#   Preprocess        : 'dtsx' turns SSIS packages into a readable summary before diffing
# A copy in <repo>\.ai-review\router.psd1 overrides this for that repo ('prr init -Repo <path>').
@{
    Ignore = @(
        '**/bin/**', '**/obj/**', '**/node_modules/**', '**/dist/**', '**/packages/**', '**/.vs/**',
        '**/package-lock.json', '**/yarn.lock', '**/*.min.js', '**/*.min.css', '**/*.map',
        '**/*.Designer.cs', '**/*.g.cs', '**/*.g.i.cs', '**/Reference.cs',
        '**/*.suo', '**/*.user', '**/*.dtproj.user', '**/*.database',
        '**/*.png', '**/*.jpg', '**/*.jpeg', '**/*.gif', '**/*.ico', '**/*.svg',
        '**/*.woff', '**/*.woff2', '**/*.ttf', '**/*.eot', '**/*.pdf', '**/*.zip', '**/*.dll', '**/*.exe'
    )
    Routes = @(
        @{
            Name         = 'playwright'
            Prompt       = 'playwright-cs'
            Include      = @('**/*.cs')
            ContentRegex = 'Microsoft\.Playwright|\bIPage\b|\bILocator\b|PageTest|BrowserTest'
        }
        @{
            Name       = 'ssis'
            Prompt     = 'ssis'
            Include    = @('**/*.dtsx', '**/*.dtproj', '**/*.conmgr', '**/*.params')
            Preprocess = 'dtsx'
        }
        @{
            Name    = 'sql'
            Prompt  = 'sql'
            Include = @('**/*.sql')
        }
        @{
            Name    = 'csharp'
            Prompt  = 'csharp-net48'
            Include = @('**/*.cs', '**/*.cshtml', '**/*.aspx', '**/*.ascx', '**/*.asax', '**/*.config', '**/*.csproj', '**/*.sln')
        }
        @{
            Name    = 'angular'
            Prompt  = 'angular-ts'
            Include = @('**/*.ts', '**/*.html', '**/*.scss', '**/*.css', '**/*.js',
                '**/package.json', '**/angular.json', '**/tsconfig*.json', '**/proxy.conf.json')
        }
        @{
            Name    = 'general'
            Prompt  = 'general'
            Include = @('**/*')
        }
    )
}
