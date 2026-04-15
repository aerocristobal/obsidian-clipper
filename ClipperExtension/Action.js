var Action = function() {};

Action.prototype = {
    run: function(arguments) {
        arguments.completionFunction({
            "title": document.title,
            "URL": window.location.href,
            "html": document.documentElement.outerHTML
        });
    }
};

var ExtensionPreprocessingJS = new Action();
