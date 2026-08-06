import UIKit

/** 启动页使用的系统 Alert 小工具，保持错误提示符合 iOS 原生交互。 */
extension UIViewController {
    func presentShellAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}
