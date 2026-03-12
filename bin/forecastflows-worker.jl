#!/usr/bin/env julia

using ForecastFlows

function main()
    ForecastFlows.serve_protocol(stdin, stdout)
end

main()
